import Synchronization
import SlipwayCoeur
import SlipwaySecurite

public typealias IdConnexion = UInt64

public struct ConfigurationMoteur: Sendable {
    public var identite: Identite
    public var nom: String
    public var capacites: Capacites
    /// Port UDP local du canal temps réel (annoncé au client dans la poignée de main).
    public var portUDP: UInt16
    public var ecransLocaux: [Ecran]
    public var disposition: Disposition
    public var raccourcis: Raccourcis

    public init(identite: Identite, nom: String, capacites: Capacites = .toutes, portUDP: UInt16 = 0, ecransLocaux: [Ecran],
                disposition: Disposition = Disposition(), raccourcis: Raccourcis = Raccourcis()) {
        self.identite = identite; self.nom = nom; self.capacites = capacites; self.portUDP = portUDP
        self.ecransLocaux = ecransLocaux; self.disposition = disposition; self.raccourcis = raccourcis
    }
}

/// Vue de l'état pour l'interface (barre de menus, diagnostic).
public struct Instantane: Equatable, Sendable {
    public struct InfoPair: Equatable, Sendable, Identifiable {
        public var id: IdPair
        public var nom: String
        public var degrade: Bool
        public var tempsReelUDP: Bool
        public var latenceMs: Double?
        public var p99Ms: Double?
        public var gigueMs: Double?
        public var tauxPertes: Double
        public var adresse: String
    }

    public struct DemandeAppairage: Equatable, Sendable, Identifiable {
        public var id: IdConnexion
        public var idPair: IdPair
        public var nom: String
        public var code: String
        public var confirmeIci: Bool
        public var adresse: String
    }

    public var moi: IdPair
    public var mode: Session.Mode
    public var pairs: [InfoPair]
    public var appairages: [DemandeAppairage]
    public var disposition: Disposition
    public var journal: [String]
    public var mouvementsPerimes: Int
    public var datagrammesRejetes: Int
    /// Appairage ouvert sur ce Mac (secondes restantes), sinon nil.
    public var appairageOuvert: Double? = nil
    /// Dernière demande d'appairage refusée faute d'appairage ouvert ici (nom et adresse).
    public var demandeRefusee: String? = nil
    /// Rôle de ce Mac (il peut changer quand l'autre Mac change le sien).
    public var principal = true
}

/// Chef d'orchestre de Slipway, sans aucune entrée-sortie propre : il relie la session (machine à états),
/// la poignée de main, les canaux scellés et les adaptateurs. Utilisable depuis n'importe quel fil :
/// tout l'état est sous un verrou unique, tenu le temps d'un calcul (quelques microsecondes).
public final class Moteur: Sendable {
    struct Connexion {
        enum Phase: Equatable { case poigneeDeMain, appairage(ici: Bool, labas: Bool), etablie }
        let id: IdConnexion
        let lien: LienReseau
        let ouverteA: Double
        var poignee: PoigneeDeMain
        var phase: Phase = .poigneeDeMain
        var flux: ScelleurFlux?
        var datagrammes: ScelleurDatagrammes?
        var canal: CanalDatagrammes?
        var materiel: MaterielSession?
        var sequenceFiable: UInt32 = 0
        var sequenceTempsReel: UInt32 = 0
        var latence = StatistiquesLatence()
        var pertes = CompteurPertes()
        var assembleur = AssembleurPressePapiers()
        var fusion = FusionMouvements()
        var dernierMouvement: Double = -1
        var idPair: IdPair? { materiel?.idPair }
    }

    struct Etat {
        var session: Session
        var connexions: [IdConnexion: Connexion] = [:]
        var prochainId: IdConnexion = 1
        var journal = JournalCirculaire<String>(capacite: 200)
        var pressePapiers = SynchroPressePapiers()
        var ecransLocaux: [Ecran]
        var dernierPing: Double = -1
        var appairageOuvertJusqua: Double = -1
        var demandeRefusee: String?
    }

    /// Effets à exécuter hors du verrou, dans l'ordre.
    enum Effet {
        case injecter(Injection)
        case figer
        case liberer(Point)
        case verifierPressePapiers
        case ecrirePressePapiers(String)
        case notifier
    }

    public let config: ConfigurationMoteur
    private let etat: Mutex<Etat>
    private let horloge: Horloge
    private let injecteur: InjecteurEntrees
    private let curseur: CurseurLocal
    private let pressePapiers: PressePapiersLocal
    private let magasin: MagasinPairs
    private let observateur: ObservateurMoteur
    private let alea: SourceAlea

    public var moi: IdPair { config.identite.id }
    /// Un Mac inconnu n'est accepté que pendant cette fenêtre, ouverte à la main sur ce Mac.
    public static let dureeAppairage = 120.0
    /// Délais au-delà desquels une connexion non authentifiée est fermée, et leur nombre maximal.
    static let delaiPoigneeDeMain = 10.0
    static let maxNonEtablies = 8
    /// Intervalle des battements de cœur (et de mesure de latence).
    public static let intervallePing = 0.25
    /// Au plus un mouvement par datagramme toutes les 4 ms (250 par seconde) : une souris à 1000 Hz saturait le Wi-Fi
    /// de petits paquets, d'où des à-coups. Les mouvements intermédiaires sont fusionnés (positions absolues, rien ne se perd).
    public static let intervalleMouvement = 0.004

    public init(config: ConfigurationMoteur, horloge: Horloge = HorlogeSysteme(), injecteur: InjecteurEntrees, curseur: CurseurLocal,
                pressePapiers: PressePapiersLocal, magasin: MagasinPairs, observateur: ObservateurMoteur, alea: SourceAlea = AleaSysteme()) {
        self.config = config
        self.horloge = horloge
        self.injecteur = injecteur
        self.curseur = curseur
        self.pressePapiers = pressePapiers
        self.magasin = magasin
        self.observateur = observateur
        self.alea = alea
        var session = Session(moi: config.identite.id, disposition: config.disposition)
        session.raccourcis = config.raccourcis
        session.mettreAJourEcrans(config.ecransLocaux, de: config.identite.id, nom: config.nom)
        etat = Mutex(Etat(session: session, ecransLocaux: config.ecransLocaux))
    }

    // MARK: - Événements locaux (fil du tap : doit rester très rapide)

    /// Rend vrai si l'événement doit être supprimé localement.
    public func evenementLocal(_ e: EvenementLocal) -> Bool {
        let t = horloge.maintenant()
        var avaler = false
        let effets: [Effet] = etat.withLock { s in
            let modeAvant = s.session.mode
            let decision = s.session.traiter(e, t: t)
            avaler = decision.avaler
            var effets = executer(decision.actions, dans: &s, t: t)
            if s.session.mode != modeAvant { effets.append(.notifier) }
            return effets
        }
        appliquer(effets)
        return avaler
    }

    public func toutRendreLocal(raison: RaisonSortie = .panique) {
        commande { s, _ in s.session.toutRendreLocal(raison: raison) }
    }

    /// Principal (sa souris passe sur les autres Mac) ou secondaire (il se laisse seulement piloter).
    /// `propager` : choix fait à la main ici, envoyé aux pairs connectés qui prennent le rôle inverse.
    public func definirPrincipal(_ oui: Bool, propager: Bool = false) {
        commande { s, _ in
            var actions = appliquerRole(oui, dans: &s)
            if propager {
                actions += s.connexions.values.filter { $0.phase == .etablie }.compactMap(\.idPair).sorted().map { .envoyer(.role(principal: oui), a: $0) }
            }
            return actions
        }
    }

    private func appliquerRole(_ oui: Bool, dans s: inout Etat) -> [Action] {
        s.session.principal = oui
        return oui ? [] : s.session.toutRendreLocal(raison: .bascule)
    }

    /// Envoie les mouvements fusionnés dont le délai est passé. À appeler toutes les 4 ms environ.
    public func viderMouvements() {
        let t = horloge.maintenant()
        etat.withLock { s in
            for id in s.connexions.keys.sorted() {
                guard let c = s.connexions[id], !c.fusion.estVide, t - c.dernierMouvement >= Self.intervalleMouvement else { continue }
                viderFusion(id, dans: &s, t: t)
            }
        }
    }

    /// Ouvre (ou referme) l'appairage d'un nouveau Mac sur ce Mac pour `Moteur.dureeAppairage` secondes.
    public func ouvrirAppairage(_ oui: Bool = true) {
        commande { s, t in
            s.appairageOuvertJusqua = oui ? t + Self.dureeAppairage : -1
            s.demandeRefusee = nil
            return [.journal(oui ? "Appairage ouvert pour 2 minutes" : "Appairage refermé")]
        }
    }

    public func basculerVers(_ pair: IdPair) {
        commande { s, _ in s.session.basculerVers(pair) }
    }

    /// Disposition modifiée par l'utilisateur (éditeur à la souris) : appliquée ici et envoyée aux pairs connectés,
    /// avec une révision supérieure à toutes celles déjà vues (horloge de Lamport : le dernier qui modifie l'emporte).
    public func modifierDisposition(_ d: Disposition) {
        commande { s, _ in
            var nouvelle = d
            nouvelle.macs[self.moi]?.ecrans = s.ecransLocaux
            nouvelle.revision = max(d.revision, s.session.disposition.revision) + 1
            s.session.remplacerDisposition(nouvelle)
            let message = Message.disposition(revision: nouvelle.revision, places: nouvelle.placesDecrites)
            return s.connexions.values.filter { $0.phase == .etablie }.compactMap(\.idPair).sorted().map { .envoyer(message, a: $0) }
        }
    }

    public func ecransLocauxChanges(_ ecrans: [Ecran]) {
        commande { s, _ in
            s.ecransLocaux = ecrans
            s.session.mettreAJourEcrans(ecrans, de: self.moi, nom: self.config.nom)
            return s.connexions.values.filter { $0.phase == .etablie }.compactMap(\.idPair)
                .map { .envoyer(.ecrans(ecrans.map(\.decrit)), a: $0) }
        }
    }

    // MARK: - Réseau

    /// Une connexion TCP vient de s'ouvrir (client : on l'a initiée ; serveur : on l'a acceptée).
    @discardableResult
    public func connexionOuverte(_ lien: LienReseau, role: MaterielSession.Role) -> IdConnexion {
        let t = horloge.maintenant()
        let id: IdConnexion = etat.withLock { s in
            let id = s.prochainId
            s.prochainId += 1
            // Trop de connexions pas encore authentifiées (inondation) : la nouvelle est fermée tout de suite.
            if s.connexions.values.count(where: { $0.phase != .etablie }) >= Self.maxNonEtablies {
                lien.fermer()
                s.journal.ajouter(horodater("Connexion refusée (trop de connexions en attente) : \(lien.description)", t: t))
                return id
            }
            var poignee = PoigneeDeMain(role: role, identite: config.identite, nom: config.nom, capacites: config.capacites,
                                        portUDP: config.portUDP, alea: alea)
            if role == .client, let sortie = try? poignee.demarrer() {
                for trame in sortie.enClair { lien.envoyer(trame) }
            }
            s.connexions[id] = Connexion(id: id, lien: lien, ouverteA: t, poignee: poignee)
            s.journal.ajouter(horodater("Connexion \(role == .client ? "sortante" : "entrante") : \(lien.description)", t: t))
            return id
        }
        observateur.moteurAChange()
        return id
    }

    public func connexionFermee(_ id: IdConnexion) {
        commande { s, t in fermer(id, dans: &s, raison: nil, t: t) }
    }

    /// Un enregistrement complet (sans son préfixe de longueur) est arrivé sur le canal fiable.
    public func enregistrementRecu(_ octets: [UInt8], connexion id: IdConnexion) {
        commande { s, t in
            guard var c = s.connexions[id] else { return [] }
            var actions: [Action] = []
            do {
                if var flux = c.flux {
                    let trame = try flux.ouvrir(octets)
                    c.flux = flux
                    s.connexions[id] = c
                    let decodee = try Codec.decoder(trame)
                    actions += traiterMessageFiable(decodee, connexion: id, dans: &s, t: t)
                } else {
                    let sortie = try c.poignee.recevoirEnClair(octets)
                    for trame in sortie.enClair { c.lien.envoyer(trame) }
                    if let m = sortie.materiel {
                        c.materiel = m
                        c.flux = ScelleurFlux(materiel: m)
                        c.datagrammes = ScelleurDatagrammes(materiel: m)
                    }
                    s.connexions[id] = c
                    for message in sortie.scelles { envoyerFiable(message, connexion: id, dans: &s) }
                }
            } catch let e as ErreurSecurite {
                if c.flux == nil, case .versionIncompatible = e {
                    c.lien.envoyer(Codec.encoder(.auRevoir(raison: .versionIncompatible, texte: "Version du protocole incompatible (attendu \(Protocole.versionMajeure).x)")))
                }
                actions += fermer(id, dans: &s, raison: "Échec de sécurité : \(e)", t: t)
            } catch {
                actions += fermer(id, dans: &s, raison: "Trame illisible : \(error)", t: t)
            }
            return actions
        }
    }

    /// Un datagramme est arrivé (canal temps réel). `retour` permet de répondre à l'expéditeur.
    /// Rend vrai s'il était authentique (l'adaptateur ferme les canaux qui n'en reçoivent plus).
    @discardableResult
    public func datagrammeRecu(_ octets: [UInt8], retour: CanalDatagrammes) -> Bool {
        var authentique = false
        commande { s, t in
            guard let idCanal = ScelleurDatagrammes.idCanal(de: octets),
                  let id = s.connexions.values.first(where: { $0.datagrammes?.idCanal == idCanal && $0.phase == .etablie })?.id,
                  var c = s.connexions[id], var dg = c.datagrammes else { return [] }
            let trame: Trame
            do {
                let clair = try dg.ouvrir(octets)
                c.datagrammes = dg
                authentique = true
                trame = try Codec.decoder(clair)
            } catch {
                c.datagrammes = dg
                s.connexions[id] = c
                return []
            }
            if c.canal !== retour { c.canal = retour }   // le serveur apprend l'adresse du client (et ses changements)
            c.pertes.noter(trame.sequence)
            s.connexions[id] = c
            guard let pair = c.idPair else { return [] }
            switch trame.message {
            case .ping(let h):
                envoyerTempsReel(.pong(horodatage: h), connexion: id, dans: &s, t: t)
                return s.session.recevoir(.ping(horodatage: h), de: pair, sequence: trame.sequence, t: t)
            case .pong(let h):
                s.connexions[id]?.latence.ajouter(allerRetour: t - Double(h) / 1e9)
                return s.session.recevoir(.pong(horodatage: h), de: pair, sequence: trame.sequence, t: t)
            case .mouvement, .defilement:
                return s.session.recevoir(trame.message, de: pair, sequence: trame.sequence, t: t)
            default:
                return []   // seuls les messages temps réel sont admis sur ce canal
            }
        }
        return authentique
    }

    /// L'utilisateur a comparé les codes à 6 chiffres affichés sur les deux Mac.
    public func confirmerAppairage(_ id: IdConnexion, accepte: Bool) {
        commande { s, t in
            guard let c = s.connexions[id], case .appairage(_, let labas) = c.phase else { return [] }
            guard accepte else {
                envoyerFiable(.auRevoir(raison: .appairageRefuse, texte: "Appairage refusé"), connexion: id, dans: &s)
                return fermer(id, dans: &s, raison: "Appairage refusé ici", t: t)
            }
            envoyerFiable(.confirmationAppairage, connexion: id, dans: &s)
            s.connexions[id]?.phase = .appairage(ici: true, labas: labas)
            return labas ? etablir(id, dans: &s, t: t, nouveauPair: true) : []
        }
    }

    /// À appeler toutes les 50 ms environ : battements de cœur, liens perdus, mouvements fusionnés en attente.
    public func tic() {
        commande { s, t in
            var actions: [Action] = []
            if t - s.dernierPing >= Self.intervallePing {
                s.dernierPing = t
                let h = UInt64(max(0, t) * 1e9)
                for id in s.connexions.keys.sorted() where s.connexions[id]?.phase == .etablie {
                    envoyerTempsReel(.ping(horodatage: h), connexion: id, dans: &s, t: t)
                }
            }
            for id in s.connexions.keys.sorted() { viderFusion(id, dans: &s, t: t) }
            // Connexions jamais authentifiées (10 s) ou appairage laissé en plan (2 min) : fermées.
            for c in s.connexions.values.sorted(by: { $0.id < $1.id }) where c.phase != .etablie {
                let limite = c.phase == .poigneeDeMain ? Self.delaiPoigneeDeMain : Self.dureeAppairage
                if t - c.ouverteA > limite { actions += fermer(c.id, dans: &s, raison: "Connexion expirée : \(c.lien.description)", t: t) }
            }
            if s.appairageOuvertJusqua >= 0, t > s.appairageOuvertJusqua { s.appairageOuvertJusqua = -1; s.demandeRefusee = nil }
            actions += s.session.tic(t: t)
            return actions
        }
        observateur.moteurAChange()
    }

    /// Rappel de l'adaptateur presse-papiers : compteur courant, et lecture paresseuse du texte.
    public func compteurPressePapiers(_ compteur: Int, lire: () -> String?) {
        let doitLire = etat.withLock { $0.pressePapiers.compteurLocal(compteur) }
        guard doitLire, let texte = lire() else { return }
        commande { s, _ in
            let messages = s.pressePapiers.preparerEnvoi(texte: texte)
            guard !messages.isEmpty else { return [] }
            for (id, c) in s.connexions.sorted(by: { $0.key < $1.key })
            where c.phase == .etablie && c.materiel?.capacites.contains(.pressePapiersTexte) == true {
                for m in messages { envoyerFiable(m, connexion: id, dans: &s) }
            }
            return [.journal("Presse-papiers envoyé (\(texte.utf8.count) octets)")]
        }
    }

    /// Liens établis, par pair (le service réseau y apprend l'adresse qui marche).
    public func liensEtablis() -> [IdPair: LienReseau] {
        etat.withLock { s in
            var liens: [IdPair: LienReseau] = [:]
            for c in s.connexions.values where c.phase == .etablie { if let p = c.idPair { liens[p] = c.lien } }
            return liens
        }
    }

    public func instantane() -> Instantane {
        etat.withLock { s in
            let pairs = s.connexions.values.filter { $0.phase == .etablie }.compactMap { c -> Instantane.InfoPair? in
                guard let m = c.materiel else { return nil }
                return Instantane.InfoPair(
                    id: m.idPair, nom: m.nomPair, degrade: s.session.etatsLiens[m.idPair] == .degrade, tempsReelUDP: c.canal != nil,
                    latenceMs: c.latence.moyenne.map { $0 * 1000 }, p99Ms: c.latence.centile(99).map { $0 * 1000 },
                    gigueMs: c.latence.gigue.map { $0 * 1000 }, tauxPertes: c.pertes.taux, adresse: c.lien.description)
            }.sorted { $0.nom < $1.nom }
            let appairages = s.connexions.values.compactMap { c -> Instantane.DemandeAppairage? in
                guard case .appairage(let ici, _) = c.phase, let m = c.materiel else { return nil }
                return Instantane.DemandeAppairage(id: c.id, idPair: m.idPair, nom: m.nomPair, code: m.codeVerification, confirmeIci: ici,
                                                   adresse: c.lien.description)
            }.sorted { $0.id < $1.id }
            let rejetes = s.connexions.values.reduce(0) { $0 + ($1.datagrammes?.rejetes ?? 0) }
            let t = horloge.maintenant()
            return Instantane(moi: moi, mode: s.session.mode, pairs: pairs, appairages: appairages, disposition: s.session.disposition,
                              journal: s.journal.elements, mouvementsPerimes: s.session.mouvementsPerimes, datagrammesRejetes: rejetes,
                              appairageOuvert: t <= s.appairageOuvertJusqua ? s.appairageOuvertJusqua - t : nil, demandeRefusee: s.demandeRefusee,
                              principal: s.session.principal)
        }
    }

    // MARK: - Interne

    /// Exécute une transformation de l'état sous verrou, puis ses effets hors verrou.
    private func commande(_ f: (inout Etat, Double) -> [Action]) {
        let t = horloge.maintenant()
        let effets: [Effet] = etat.withLock { s in
            let modeAvant = s.session.mode
            var effets = executer(f(&s, t), dans: &s, t: t)
            if s.session.mode != modeAvant { effets.append(.notifier) }
            return effets
        }
        appliquer(effets)
    }

    private func appliquer(_ effets: [Effet]) {
        var notifier = false
        for e in effets {
            switch e {
            case .injecter(let i): injecteur.injecter(i)
            case .figer: curseur.figer()
            case .liberer(let p): curseur.liberer(a: p)
            case .verifierPressePapiers: pressePapiers.signalerChangementPossible()
            case .ecrirePressePapiers(let texte):
                let compteur = pressePapiers.ecrire(texte: texte)
                etat.withLock { $0.pressePapiers.ecritParNous(compteur: compteur) }
            case .notifier: notifier = true
            }
        }
        if notifier { observateur.moteurAChange() }
    }

    /// Envois réseau faits tout de suite (sous verrou : l'ordre des compteurs de scellement est garanti),
    /// le reste est rendu sous forme d'effets.
    private func executer(_ actions: [Action], dans s: inout Etat, t: Double) -> [Effet] {
        var effets: [Effet] = []
        var file = actions[...]
        while let a = file.popFirst() {
            switch a {
            case .envoyer(let m, let pair):
                // Un clic ou une touche ne doit pas doubler le dernier mouvement encore en attente.
                if let id = connexionEtablie(pour: pair, dans: s) { viderFusion(id, dans: &s, t: t); envoyerFiable(m, connexion: id, dans: &s) }
            case .envoyerTempsReel(let m, let pair):
                if let id = connexionEtablie(pour: pair, dans: s) { envoyerTempsReel(m, connexion: id, dans: &s, t: t) }
            case .figerCurseurLocal: effets.append(.figer)
            case .libererCurseurLocal(let p): effets.append(.liberer(p))
            case .injecter(let i): effets.append(.injecter(i))
            case .verifierPressePapiers: effets.append(.verifierPressePapiers)
            case .ecrirePressePapiers(let texte): effets.append(.ecrirePressePapiers(texte))
            case .couperLien(let pair):
                for id in s.connexions.values.filter({ $0.idPair == pair }).map(\.id) {
                    s.connexions[id]?.lien.fermer()
                    s.connexions[id] = nil
                }
                effets.append(.notifier)
            case .journal(let texte):
                s.journal.ajouter(horodater(texte, t: t))
                effets.append(.notifier)
            }
        }
        return effets
    }

    private func horodater(_ texte: String, t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return "[\(ms / 1000).\(String(ms % 1000 + 1000).dropFirst())] \(texte)"
    }

    private func connexionEtablie(pour pair: IdPair, dans s: Etat) -> IdConnexion? {
        s.connexions.values.first { $0.phase == .etablie && $0.idPair == pair }?.id
    }

    private func envoyerFiable(_ m: Message, connexion id: IdConnexion, dans s: inout Etat) {
        guard var c = s.connexions[id], var flux = c.flux else { return }
        c.sequenceFiable &+= 1
        let enregistrement = flux.sceller(Codec.encoder(Trame(sequence: c.sequenceFiable, message: m)))
        c.flux = flux
        s.connexions[id] = c
        c.lien.envoyer(enregistrement)
    }

    /// Envoie le mouvement fusionné en attente, si le canal le permet.
    private func viderFusion(_ id: IdConnexion, dans s: inout Etat, t: Double) {
        guard var c = s.connexions[id], !c.fusion.estVide, c.canal?.estSature != true, let m = c.fusion.prendre() else { return }
        s.connexions[id] = c
        envoyerTempsReel(.mouvement(m), connexion: id, dans: &s, t: t, immediat: true)
    }

    /// Canal temps réel si disponible, sinon repli sur le canal fiable (pare-feu qui bloque l'UDP).
    private func envoyerTempsReel(_ m: Message, connexion id: IdConnexion, dans s: inout Etat, t: Double, immediat: Bool = false) {
        guard var c = s.connexions[id] else { return }
        var message = m
        if case .mouvement(let mv) = m {
            // Trop tôt depuis le dernier envoi, ou canal saturé : fusionné, parti au prochain `viderMouvements`.
            if c.canal?.estSature == true || (!immediat && t - c.dernierMouvement < Self.intervalleMouvement) {
                c.fusion.ajouter(mv)
                s.connexions[id] = c
                return
            }
            if !c.fusion.estVide {
                c.fusion.ajouter(mv)
                if let fusionne = c.fusion.prendre() { message = .mouvement(fusionne) }
            }
            c.dernierMouvement = t
            s.connexions[id] = c
        }
        guard let canal = c.canal, var dg = c.datagrammes else {
            if case .ping = message { return }   // sans UDP, le canal fiable suffit à prouver que le lien vit
            envoyerFiable(message, connexion: id, dans: &s)
            return
        }
        c.sequenceTempsReel &+= 1
        let datagramme = dg.sceller(Codec.encoder(Trame(sequence: c.sequenceTempsReel, message: message)))
        c.datagrammes = dg
        s.connexions[id] = c
        canal.envoyer(datagramme)
    }

    private func traiterMessageFiable(_ trame: Trame, connexion id: IdConnexion, dans s: inout Etat, t: Double) -> [Action] {
        guard var c = s.connexions[id] else { return [] }
        switch trame.message {
        case .preuve(let signature):
            do { try c.poignee.recevoirPreuve(signature) } catch {
                s.connexions[id] = c
                return fermer(id, dans: &s, raison: "Preuve d'identité invalide", t: t)
            }
            s.connexions[id] = c
            guard let m = c.materiel else { return [] }
            if magasin.estConnu(m.clePairIdentite) { return etablir(id, dans: &s, t: t, nouveauPair: false) }
            // Mac inconnu : seulement si l'appairage a été ouvert à la main ici, et une seule demande à la fois.
            let enCours = s.connexions.values.contains { $0.id != id && { if case .appairage = $0.phase { true } else { false } }($0) }
            guard t <= s.appairageOuvertJusqua, !enCours else {
                s.demandeRefusee = "« \(m.nomPair) » (\(c.lien.description))"
                envoyerFiable(.auRevoir(raison: .appairageRefuse, texte: "Appairage non ouvert sur ce Mac"), connexion: id, dans: &s)
                return fermer(id, dans: &s, raison: "Demande d'appairage de « \(m.nomPair) » ignorée : appairage non ouvert ici (\(c.lien.description))", t: t)
            }
            s.connexions[id]?.phase = .appairage(ici: false, labas: false)
            return [.journal("Appairage demandé par « \(m.nomPair) » : comparez le code \(m.codeVerification)")]
        case .confirmationAppairage:
            guard case .appairage(let ici, _) = c.phase else { return [] }
            s.connexions[id]?.phase = .appairage(ici: ici, labas: true)
            return ici ? etablir(id, dans: &s, t: t, nouveauPair: true) : []
        case .auRevoir(let raison, let texte):
            return fermer(id, dans: &s, raison: "Le pair a fermé (\(raison)) : \(texte)", t: t)
        case .ping(let h):
            if c.phase == .etablie { envoyerFiable(.pong(horodatage: h), connexion: id, dans: &s) }
        case .pong(let h):
            s.connexions[id]?.latence.ajouter(allerRetour: t - Double(h) / 1e9)
        case .pressePapiersOffre, .pressePapiersMorceau:
            guard c.phase == .etablie else { return [] }
            let resultat = c.assembleur.recevoir(trame.message)
            s.connexions[id] = c
            switch resultat {
            case .enCours: break
            case .rejete(let pourquoi): return [.journal("Presse-papiers ignoré : \(pourquoi)")]
            case .termine(let texte, let empreinte):
                guard s.pressePapiers.texteRecu(empreinte: empreinte) else { return [] }
                return [.ecrirePressePapiers(texte), .journal("Presse-papiers reçu (\(texte.utf8.count) octets)")]
            }
        case .ecrans(let liste):
            guard c.phase == .etablie, let pair = c.idPair else { return [] }
            s.session.mettreAJourEcrans(liste.map(Ecran.init), de: pair, nom: c.materiel?.nomPair ?? "")
        case .role(let principalLabas):
            guard c.phase == .etablie else { return [] }
            // L'autre devient principal : ce Mac passe secondaire. Il devient secondaire : ce Mac reprend la main,
            // seulement s'il n'y a que lui en face (avec plusieurs Mac, on ne devine pas lequel doit piloter).
            let pairs = s.connexions.values.filter { $0.phase == .etablie }.count
            guard principalLabas || pairs == 1, s.session.principal == principalLabas else { break }
            return appliquerRole(!principalLabas, dans: &s)
                + [.journal("\(c.materiel?.nomPair ?? "L'autre Mac") est passé \(principalLabas ? "principal" : "secondaire") : ce Mac devient \(principalLabas ? "secondaire" : "principal")")]
        case .disposition(let revision, let places):
            guard c.phase == .etablie else { return [] }
            if s.session.dispositionRecue(revision: revision, places: places) {
                return [.journal("Disposition reçue de \(c.materiel?.nomPair ?? "?") (révision \(revision))")]
            }
        default:
            guard c.phase == .etablie, let pair = c.idPair else { return [] }
            return s.session.recevoir(trame.message, de: pair, sequence: trame.sequence, t: t)
        }
        if c.phase == .etablie, let pair = c.idPair {
            return s.session.recevoir(.ping(horodatage: 0), de: pair, sequence: 0, t: t)   // tout message prouve que le lien vit
        }
        return []
    }

    private func etablir(_ id: IdConnexion, dans s: inout Etat, t: Double, nouveauPair: Bool) -> [Action] {
        guard var c = s.connexions[id], let m = c.materiel else { return [] }
        if nouveauPair {
            magasin.memoriser(clePublique: m.clePairIdentite, nom: m.nomPair)
            s.appairageOuvertJusqua = -1
            s.demandeRefusee = nil
        }
        // Doublon (les deux Mac se sont connectés en même temps) : on garde la connexion initiée par le plus petit identifiant.
        if let autre = connexionEtablie(pour: m.idPair, dans: s) {
            let clientVoulu = min(moi, m.idPair)
            let clientDeCelleCi = m.role == .client ? moi : m.idPair
            if clientDeCelleCi != clientVoulu {
                envoyerFiable(.auRevoir(raison: .occupe, texte: "Connexion en double"), connexion: id, dans: &s)
                return fermer(id, dans: &s, raison: "Connexion en double avec \(m.nomPair)", t: t)
            }
            envoyerFiable(.auRevoir(raison: .occupe, texte: "Connexion en double"), connexion: autre, dans: &s)
            _ = fermer(autre, dans: &s, raison: "Connexion en double avec \(m.nomPair)", t: t)
        }
        c.phase = .etablie
        if m.role == .client, let port = m.portUDPPair, port != 0 { c.canal = c.lien.ouvrirCanalTempsReel(port: port) }
        s.connexions[id] = c
        var actions = s.session.connecte(m.idPair, t: t)
        if s.session.disposition.macs[m.idPair] == nil {
            s.session.mettreAJourEcrans([], de: m.idPair, nom: m.nomPair)
        }
        envoyerFiable(.ecrans(s.ecransLocaux.map(\.decrit)), connexion: id, dans: &s)
        let disposition = s.session.disposition
        if disposition.revision > 0 {
            envoyerFiable(.disposition(revision: disposition.revision, places: disposition.placesDecrites), connexion: id, dans: &s)
        }
        if c.canal != nil { envoyerTempsReel(.ping(horodatage: UInt64(max(0, t) * 1e9)), connexion: id, dans: &s, t: t) }
        actions.append(.journal(nouveauPair ? "Nouveau Mac appairé : \(m.nomPair)" : "Mac reconnu : \(m.nomPair)"))
        return actions
    }

    @discardableResult
    private func fermer(_ id: IdConnexion, dans s: inout Etat, raison: String?, t: Double) -> [Action] {
        guard let c = s.connexions.removeValue(forKey: id) else { return [] }
        c.lien.fermer()
        var actions: [Action] = []
        if let raison { actions.append(.journal(raison)) }
        if c.phase == .etablie, let pair = c.idPair, connexionEtablie(pour: pair, dans: s) == nil {
            actions += s.session.deconnecte(pair)
        }
        return actions
    }
}
