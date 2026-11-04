/// Machine à états de Slipway, symétrique : chaque Mac peut piloter les autres ou être piloté.
///
///     local ──(bord franchi / raccourci)──► pilote(pair)        (on envoie nos entrées au pair)
///     local ◄──(retour par le bord / panique / perte du lien / veille)── pilote(pair)
///     local ──(message Entree reçu)──► pilotéPar(pair)          (on injecte ce que le pair envoie)
///     local ◄──(Sortie / ToutRelacher / perte du lien / veille / panique locale)── pilotéPar(pair)
///
/// Règles de fiabilité :
/// - toute sortie de `pilotéPar` relâche tout ce qui a été injecté (aucune touche coincée) ;
/// - un relâchement va toujours là où l'appui est allé, même après une bascule ;
/// - pas de bascule tant qu'une touche ordinaire ou un bouton est enfoncé ;
/// - plus de nouvelles du pair pendant `delaiPerte` : on rend tout en local.
public struct Session: Sendable {
    public enum Mode: Equatable, Sendable {
        case local
        case pilote(IdPair)
        case piloteePar(IdPair)
    }

    public enum EtatLien: Equatable, Sendable { case bon, degrade }

    public let moi: IdPair
    public private(set) var mode: Mode = .local
    public private(set) var disposition: Disposition
    public var raccourcis = Raccourcis()
    /// Mac secondaire : il se laisse piloter, mais sa propre souris ne passe jamais ses bords (ni ses raccourcis vers
    /// un autre Mac). Évite qu'il prenne la main sur le Mac principal par accident.
    public var principal = true
    /// Au-delà, le lien est signalé dégradé (3 battements de 250 ms manqués).
    public var delaiDegrade: Double = 0.75
    /// Au-delà, le contrôle est rendu en local et les touches relâchées.
    public var delaiPerte: Double = 2.0

    public private(set) var connectes: Set<IdPair> = []
    public private(set) var etatsLiens: [IdPair: EtatLien] = [:]
    private var dernierMessage: [IdPair: Double] = [:]

    // Côté Mac qui capture.
    public private(set) var positionLocale: Point = .zero
    public private(set) var positionDistante: Point = .zero
    private var positionSortieLocale: Point = .zero
    private var routes: [UInt16: Destination] = [:]
    private var boutonsLocaux: Set<BoutonSouris> = []
    private var boutonsDistants: Set<BoutonSouris> = []
    private var modificateurs: Modificateurs = []
    private var debutPressionBord: Double?
    /// Dernier appui, répétition ou relâchement vu (sert à repérer une touche dont on a manqué le relâchement).
    private var derniereTouche: Double = -.infinity
    /// Sans nouvelle du clavier depuis ce délai, une touche encore notée enfoncée est oubliée (plus que la répétition la plus lente).
    public var delaiToucheOubliee: Double = 3

    // Côté Mac piloté.
    public private(set) var injections = SuiviInjections()
    public private(set) var positionInjectee: Point = .zero
    private var derniereSequenceMouvement: UInt32?
    public private(set) var mouvementsPerimes = 0

    private var dispositionActive: Disposition

    public init(moi: IdPair, disposition: Disposition) {
        self.moi = moi
        self.disposition = disposition
        self.dispositionActive = disposition
        recalculerDispositionActive()
    }

    // MARK: - Configuration

    /// Disposition reçue d'un pair : appliquée si sa révision est plus récente.
    public mutating func dispositionRecue(revision: UInt64, places: [PlaceDecrite]) -> Bool {
        guard disposition.appliquer(revision: revision, places: places) else { return false }
        recalculerDispositionActive()
        return true
    }

    public mutating func remplacerDisposition(_ d: Disposition) {
        disposition = d
        recalculerDispositionActive()
    }

    /// Mise à jour des écrans d'un Mac (message `Ecrans` reçu, ou reconfiguration locale).
    public mutating func mettreAJourEcrans(_ ecrans: [Ecran], de mac: IdPair, nom: String) {
        if var place = disposition.macs[mac] {
            let etaitVide = place.ecrans.isEmpty
            place.ecrans = ecrans
            if !nom.isEmpty { place.nom = nom }
            disposition.macs[mac] = place
            if etaitVide, mac != moi, disposition.revision == 0 { disposition.placerAutomatiquement(mac) }
        } else {
            disposition.macs[mac] = PlaceMac(nom: nom, ecrans: ecrans)
            if mac != moi { disposition.placerAutomatiquement(mac) }
        }
        recalculerDispositionActive()
    }

    private mutating func recalculerDispositionActive() {
        var d = disposition
        d.macs = d.macs.filter { $0.key == moi || connectes.contains($0.key) }
        dispositionActive = d
    }

    /// Mac accessibles par raccourci, de gauche à droite puis de haut en bas (le n-ième = ⌃⌥⌘n).
    public var ordreRaccourcis: [IdPair] {
        dispositionActive.macs.compactMap { id, place in place.englobantVirtuel.map { (id, $0) } }
            .sorted { ($0.1.minX, $0.1.minY, $0.0.rawValue) < ($1.1.minX, $1.1.minY, $1.0.rawValue) }
            .map(\.0)
    }

    // MARK: - Liens

    public mutating func connecte(_ pair: IdPair, t: Double) -> [Action] {
        connectes.insert(pair)
        dernierMessage[pair] = t
        etatsLiens[pair] = .bon
        recalculerDispositionActive()
        return [.journal("Lien établi avec \(nomDe(pair))")]
    }

    public mutating func deconnecte(_ pair: IdPair) -> [Action] {
        guard connectes.contains(pair) else { return [] }
        connectes.remove(pair)
        dernierMessage[pair] = nil
        etatsLiens[pair] = nil
        recalculerDispositionActive()
        var actions: [Action] = [.journal("Lien perdu avec \(nomDe(pair))")]
        routes = routes.filter { $0.value != .pair(pair) }
        switch mode {
        case .pilote(pair):
            boutonsDistants.removeAll()
            mode = .local
            actions.append(.libererCurseurLocal(a: positionSortieLocale))
        case .piloteePar(pair):
            actions += relacherInjections()
            mode = .local
        default: break
        }
        return actions
    }

    /// À appeler régulièrement (≥ 4 fois par seconde) : détecte les liens dégradés ou perdus.
    public mutating func tic(t: Double) -> [Action] {
        var actions: [Action] = []
        for pair in connectes.sorted() {
            let age = t - (dernierMessage[pair] ?? t)
            if age > delaiPerte {
                actions += deconnecte(pair)
                actions.append(.couperLien(pair))
            } else {
                let etat: EtatLien = age > delaiDegrade ? .degrade : .bon
                if etatsLiens[pair] != etat {
                    etatsLiens[pair] = etat
                    actions.append(.journal(etat == .degrade ? "Lien dégradé avec \(nomDe(pair))" : "Lien rétabli avec \(nomDe(pair))"))
                }
            }
        }
        return actions
    }

    // MARK: - Commandes

    /// Raccourci panique, veille, verrouillage, arrêt : tout revient en local, rien ne reste enfoncé nulle part.
    public mutating func toutRendreLocal(raison: RaisonSortie) -> [Action] {
        var actions: [Action] = []
        switch mode {
        case .local:
            return []
        case .pilote(let pair):
            actions.append(.envoyer(.toutRelacher, a: pair))
            actions.append(.envoyer(.sortie(raison), a: pair))
            actions.append(.libererCurseurLocal(a: positionSortieLocale))
            routes = routes.filter { $0.value != .pair(pair) }
            boutonsDistants.removeAll()
        case .piloteePar(let pair):
            actions += relacherInjections()
            actions.append(.envoyer(.sortie(raison), a: pair))
        }
        mode = .local
        actions.append(.journal("Tout rendu en local (\(raison))"))
        return actions
    }

    /// Bascule directe vers un Mac (raccourci ⌃⌥⌘n), au centre de son écran principal.
    public mutating func basculerVers(_ cible: IdPair) -> [Action] {
        guard !aQuelqueChoseDEnfonce else { return [] }
        if cible == moi {
            guard case .pilote = mode else { return [] }
            return retourLocal(entree: positionSortieLocale)
        }
        guard principal, connectes.contains(cible), let place = dispositionActive.macs[cible],
              let ecran = place.ecrans.first(where: \.principal) ?? place.ecrans.first else { return [] }
        let entree = ecran.cadre.centre
        switch mode {
        case .local:
            positionSortieLocale = positionLocale
            return entrerChez(cible, a: entree, actionsAvant: [.figerCurseurLocal])
        case .pilote(let actuel) where actuel != cible:
            return entrerChez(cible, a: entree, actionsAvant: [.envoyer(.sortie(.bascule), a: actuel)])
        default:
            return []
        }
    }

    // MARK: - Événements capturés localement

    public struct Decision: Equatable, Sendable {
        /// Vrai : l'événement est supprimé localement (il part chez un pair ou a été consommé par un raccourci).
        public var avaler: Bool
        public var actions: [Action]
        public static let laisserPasser = Decision(avaler: false, actions: [])
    }

    public mutating func traiter(_ e: EvenementLocal, t: Double) -> Decision {
        if case .touche(let usage, let enfonce, _, let mods) = e, let d = raccourci(usage: usage, enfonce: enfonce, mods: mods) {
            return d
        }
        switch mode {
        case .local, .piloteePar:
            return traiterEnLocal(e, t: t)
        case .pilote(let pair):
            return traiterEnPilotage(e, pair: pair, t: t)
        }
    }

    private mutating func raccourci(usage: UInt16, enfonce: Bool, mods: Modificateurs) -> Decision? {
        guard mods.correspondExactement(a: raccourcis.groupes) else { return nil }
        let estToutLocal = usage == raccourcis.toucheToutLocal
        let numero = (CodeTouche.chiffre1...CodeTouche.chiffre9).contains(usage) ? Int(usage - CodeTouche.chiffre1) : nil
        guard estToutLocal || numero != nil else { return nil }
        guard enfonce else { return Decision(avaler: true, actions: []) }   // le relâchement est avalé aussi
        if estToutLocal { return Decision(avaler: true, actions: toutRendreLocal(raison: .panique)) }
        let ordre = ordreRaccourcis
        guard let n = numero, n < ordre.count else { return Decision(avaler: true, actions: []) }
        return Decision(avaler: true, actions: basculerVers(ordre[n]))
    }

    private var aQuelqueChoseDEnfonce: Bool {
        !boutonsLocaux.isEmpty || !boutonsDistants.isEmpty || routes.keys.contains { !CodeTouche.estModificateur($0) }
    }

    private mutating func traiterEnLocal(_ e: EvenementLocal, t: Double) -> Decision {
        switch e {
        case .mouvement(let position, let delta, let glisse):
            positionLocale = position
            // La vraie souris de ce Mac bouge alors qu'un pair le pilote (nos propres injections sont filtrées en
            // amont) : ce Mac reprend la main, sinon il resterait bloqué « piloté » sans plus pouvoir passer ses bords.
            var reprise: [Action] = []
            if case .piloteePar = mode, delta != .zero { reprise = toutRendreLocal(raison: .bascule) }
            // Relâchement manqué (macOS a coupé la capture un instant, verrouillage, saisie sécurisée) : sans cela, les
            // bords resteraient bloqués jusqu'au prochain appui sur ce bouton ou cette touche.
            if !glisse, !boutonsLocaux.isEmpty { boutonsLocaux.removeAll(); reprise.append(.journal("Bouton resté enfoncé oublié (relâchement manqué)")) }
            reprise += oublierTouchesPerimees(t: t)
            let resteIci = Decision(avaler: false, actions: reprise)
            guard mode == .local, principal, !aQuelqueChoseDEnfonce else { debutPressionBord = nil; return resteIci }
            guard case .bascule(let cible, let entree, let sortie) = dispositionActive.deplacer(depuis: position, de: delta, sur: moi) else {
                debutPressionBord = nil
                return resteIci
            }
            guard bordAssezPousse(t: t) else { return resteIci }
            positionSortieLocale = sortie
            return Decision(avaler: true, actions: reprise + entrerChez(cible, a: entree, actionsAvant: [.figerCurseurLocal]))
        case .bouton(let b, let enfonce, _, let position):
            positionLocale = position
            if enfonce { boutonsLocaux.insert(b) } else { boutonsLocaux.remove(b) }
            return .laisserPasser
        case .touche(let usage, let enfonce, let repetition, let mods):
            modificateurs = mods
            derniereTouche = t
            if enfonce { routes[usage] = .local } else {
                // Relâchement d'une touche enfoncée pendant un pilotage : il doit partir chez ce pair.
                if case .pair(let pair) = routes.removeValue(forKey: usage) {
                    return Decision(avaler: true, actions: [.envoyer(.touche(EvenementTouche(usage: usage, enfonce: false, repetition: false, modificateurs: mods)), a: pair)])
                }
                if !repetition, Self.estCopie(usage: usage, mods: mods) { return Decision(avaler: false, actions: [.verifierPressePapiers]) }
            }
            return .laisserPasser
        case .defilement, .toucheSysteme:
            return .laisserPasser
        }
    }

    private mutating func traiterEnPilotage(_ e: EvenementLocal, pair: IdPair, t: Double) -> Decision {
        switch e {
        case .mouvement(_, let delta, let glisse):
            var oublis = oublierTouchesPerimees(t: t)
            if !glisse, !boutonsDistants.isEmpty {
                // Relâchement manqué : envoyé au pair, qui sinon resterait en train de glisser.
                for b in boutonsDistants.sorted(by: { $0.rawValue < $1.rawValue }) {
                    oublis.append(.envoyer(.bouton(EvenementBouton(bouton: b, enfonce: false, nbClics: 1, x: Float(positionDistante.x), y: Float(positionDistante.y))), a: pair))
                }
                boutonsDistants.removeAll()
                oublis.append(.journal("Bouton resté enfoncé oublié (relâchement manqué)"))
            }
            var decision = deplacerEnPilotage(delta: delta, pair: pair, t: t)
            decision.actions = oublis + decision.actions
            return decision
        case .bouton(let b, let enfonce, let nbClics, _):
            if enfonce { boutonsDistants.insert(b) } else { boutonsDistants.remove(b) }
            let ev = EvenementBouton(bouton: b, enfonce: enfonce, nbClics: nbClics, x: Float(positionDistante.x), y: Float(positionDistante.y))
            return Decision(avaler: true, actions: [.envoyer(.bouton(ev), a: pair)])
        case .defilement(let d):
            return Decision(avaler: true, actions: [.envoyerTempsReel(.defilement(d), a: pair)])
        case .touche(let usage, let enfonce, let repetition, let mods):
            modificateurs = mods
            derniereTouche = t
            let destination: Destination
            if enfonce {
                destination = repetition ? (routes[usage] ?? .pair(pair)) : .pair(pair)
                routes[usage] = destination
            } else {
                destination = routes.removeValue(forKey: usage) ?? .pair(pair)
            }
            guard case .pair(let cible) = destination else { return .laisserPasser }   // appui fait en local : relâché en local
            return Decision(avaler: true, actions: [.envoyer(.touche(EvenementTouche(usage: usage, enfonce: enfonce, repetition: repetition, modificateurs: mods)), a: cible)])
        case .toucheSysteme(let ts):
            return Decision(avaler: true, actions: [.envoyer(.toucheSysteme(ts), a: pair)])
        }
    }

    private mutating func deplacerEnPilotage(delta: Point, pair: IdPair, t: Double) -> Decision {
        let facteur = dispositionActive.macs[pair]?.facteurVitesse ?? 1
        let d = Point(x: delta.x * facteur, y: delta.y * facteur)
        let resultat = dispositionActive.deplacer(depuis: positionDistante, de: d, sur: pair)
        switch resultat {
        case .bascule(let cible, let entree, let sortie) where !aQuelqueChoseDEnfonce:
            guard bordAssezPousse(t: t) else { return envoyerMouvement(vers: sortie, delta: d, pair: pair) }
            if cible == moi { return Decision(avaler: true, actions: retourLocal(entree: entree)) }
            return Decision(avaler: true, actions: entrerChez(cible, a: entree, actionsAvant: [.envoyer(.sortie(.bascule), a: pair)]))
        case .bascule(_, _, let sortie):
            return envoyerMouvement(vers: sortie, delta: d, pair: pair)
        case .reste(let p):
            debutPressionBord = nil
            return envoyerMouvement(vers: p, delta: d, pair: pair)
        }
    }

    /// Touche ordinaire encore notée enfoncée alors que le clavier ne dit plus rien depuis `delaiToucheOubliee` :
    /// son relâchement a été manqué. Elle est oubliée (relâchée chez le pair où elle était partie).
    private mutating func oublierTouchesPerimees(t: Double) -> [Action] {
        guard t - derniereTouche > delaiToucheOubliee else { return [] }
        let perimees = routes.filter { !CodeTouche.estModificateur($0.key) }.sorted { $0.key < $1.key }
        guard !perimees.isEmpty else { return [] }
        var actions: [Action] = [.journal("Touche restée enfoncée oubliée (relâchement manqué)")]
        for (usage, destination) in perimees {
            routes[usage] = nil
            if case .pair(let p) = destination {
                actions.append(.envoyer(.touche(EvenementTouche(usage: usage, enfonce: false, repetition: false, modificateurs: modificateurs)), a: p))
            }
        }
        return actions
    }

    private mutating func envoyerMouvement(vers p: Point, delta: Point, pair: IdPair) -> Decision {
        positionDistante = p
        var masque: UInt8 = 0
        for b in boutonsDistants where b.rawValue < 8 { masque |= 1 << b.rawValue }
        let m = Mouvement(dx: Float(delta.x), dy: Float(delta.y), x: Float(p.x), y: Float(p.y), boutons: masque)
        return Decision(avaler: true, actions: [.envoyerTempsReel(.mouvement(m), a: pair)])
    }

    private mutating func bordAssezPousse(t: Double) -> Bool {
        let delai = dispositionActive.reglages.delaiBord
        guard delai > 0 else { debutPressionBord = nil; return true }
        guard let debut = debutPressionBord else { debutPressionBord = t; return false }
        if t - debut >= delai { debutPressionBord = nil; return true }
        return false
    }

    private mutating func entrerChez(_ cible: IdPair, a entree: Point, actionsAvant: [Action]) -> [Action] {
        mode = .pilote(cible)
        positionDistante = entree
        debutPressionBord = nil
        let e = Entree(x: Float(entree.x), y: Float(entree.y), modificateurs: modificateurs)
        return actionsAvant + [.envoyer(.entree(e), a: cible), .verifierPressePapiers, .journal("Pilotage de \(nomDe(cible))")]
    }

    private mutating func retourLocal(entree: Point) -> [Action] {
        guard case .pilote(let pair) = mode else { return [] }
        mode = .local
        debutPressionBord = nil
        positionLocale = entree
        return [.envoyer(.sortie(.bascule), a: pair), .libererCurseurLocal(a: entree), .journal("Retour en local")]
    }

    static func estCopie(usage: UInt16, mods: Modificateurs) -> Bool {
        (usage == CodeTouche.c || usage == CodeTouche.x) && !mods.intersection(.cmd).isEmpty
    }

    private func nomDe(_ pair: IdPair) -> String { disposition.macs[pair]?.nom ?? pair.rawValue }

    // MARK: - Messages reçus d'un pair

    /// `sequence` = numéro de séquence de la trame (sert à écarter les mouvements périmés sur le canal temps réel).
    public mutating func recevoir(_ message: Message, de pair: IdPair, sequence: UInt32, t: Double) -> [Action] {
        dernierMessage[pair] = t
        if etatsLiens[pair] == .degrade {
            etatsLiens[pair] = .bon
        }
        let estPilotePar = mode == .piloteePar(pair)
        switch message {
        case .entree(let e):
            var actions: [Action] = []
            switch mode {
            case .pilote: actions += toutRendreLocal(raison: .bascule)
            case .piloteePar(let autre) where autre != pair: actions += toutRendreLocal(raison: .bascule)
            default: break
            }
            mode = .piloteePar(pair)
            derniereSequenceMouvement = nil
            positionInjectee = bornerLocal(Point(x: Double(e.x), y: Double(e.y)))
            // Premier mouvement : rend le curseur visible même sans souris physique sur ce Mac.
            actions.append(injecter(.mouvement(position: positionInjectee, delta: .zero, boutonsEnfonces: [])))
            actions.append(.journal("Piloté par \(nomDe(pair))"))
            return actions
        case .mouvement(let m) where estPilotePar:
            if let derniere = derniereSequenceMouvement, !Sequence32.plusRecent(sequence, que: derniere) {
                mouvementsPerimes += 1
                return []
            }
            derniereSequenceMouvement = sequence
            positionInjectee = bornerLocal(Point(x: Double(m.x), y: Double(m.y)))
            return [injecter(.mouvement(position: positionInjectee, delta: Point(x: Double(m.dx), y: Double(m.dy)),
                                        boutonsEnfonces: injections.boutons.sorted()))]
        case .bouton(let b) where estPilotePar:
            positionInjectee = bornerLocal(Point(x: Double(b.x), y: Double(b.y)))
            return [injecter(.bouton(b.bouton, enfonce: b.enfonce, nbClics: max(1, b.nbClics), position: positionInjectee))]
        case .defilement(let d) where estPilotePar:
            return [injecter(.defilement(d, position: positionInjectee))]
        case .touche(let tch) where estPilotePar:
            var actions = [injecter(.touche(usage: tch.usage, enfonce: tch.enfonce, repetition: tch.repetition, modificateurs: tch.modificateurs))]
            if !tch.enfonce, Self.estCopie(usage: tch.usage, mods: tch.modificateurs) { actions.append(.verifierPressePapiers) }
            return actions
        case .toucheSysteme(let ts) where estPilotePar:
            return [injecter(.toucheSysteme(ts))]
        case .toutRelacher:
            return relacherInjections()
        case .sortie(let raison):
            if estPilotePar {
                mode = .local
                return relacherInjections() + [.verifierPressePapiers, .journal("Fin du pilotage par \(nomDe(pair)) (\(raison))")]
            }
            if mode == .pilote(pair) {
                // Le pair nous rend la main (panique ou veille de son côté).
                mode = .local
                routes = routes.filter { $0.value != .pair(pair) }
                boutonsDistants.removeAll()
                return [.libererCurseurLocal(a: positionSortieLocale), .journal("\(nomDe(pair)) a rendu la main (\(raison))")]
            }
            return []
        case .ecrans(let liste):
            mettreAJourEcrans(liste.map(Ecran.init), de: pair, nom: disposition.macs[pair]?.nom ?? "")
            return []
        default:
            return []
        }
    }

    private mutating func injecter(_ i: Injection) -> Action {
        injections.noter(i)
        return .injecter(i)
    }

    private mutating func relacherInjections() -> [Action] {
        injections.toutRelacher(position: positionInjectee).map { .injecter($0) }
    }

    private func bornerLocal(_ p: Point) -> Point {
        disposition.macs[moi]?.bornerLocal(p) ?? p
    }
}
