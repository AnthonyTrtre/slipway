#if os(macOS)
import Foundation
import Network
import OSLog
import Synchronization
import SlipwayCoeur
import SlipwaySecurite
import SlipwayMoteur

/// Ports fixes de Slipway (hors de la plage 24800-24804 de Synergy, pour pouvoir cohabiter pendant les essais).
public enum PortsSlipway {
    public static let tcp: UInt16 = 24850
    public static let udp: UInt16 = 24851
}

/// Paramètres réseau communs. Le pair-à-pair Apple (AWDL, le Wi-Fi d'AirDrop) n'est jamais utilisé pour nos
/// connexions (`includePeerToPeer = false`). Cela n'empêche pas AirDrop/Handoff de perturber la radio Wi-Fi
/// d'à côté : d'où la mesure de gigue affichée et le conseil « câble ou Wi-Fi 5/6 GHz ».
enum ParametresReseau {
    static func tcp() -> NWParameters {
        let options = NWProtocolTCP.Options()
        options.noDelay = true            // Nagle coupé : un clic part tout de suite
        options.enableKeepalive = true
        options.keepaliveIdle = 2
        options.keepaliveInterval = 1
        options.keepaliveCount = 2
        options.connectionTimeout = 5
        let p = NWParameters(tls: nil, tcp: options)
        commun(p)
        return p
    }

    static func udp() -> NWParameters {
        let p = NWParameters.udp
        commun(p)
        return p
    }

    private static func commun(_ p: NWParameters) {
        p.serviceClass = .interactiveVoice   // marquage QoS « temps réel »
        p.includePeerToPeer = false
        p.prohibitedInterfaceTypes = [.cellular]
        p.allowLocalEndpointReuse = true
    }

    static func decrire(_ chemin: NWPath?) -> String {
        guard let chemin else { return "?" }
        if chemin.usesInterfaceType(.wiredEthernet) { return "Ethernet" }
        if chemin.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if chemin.usesInterfaceType(.other) { return "autre (Thunderbolt ?)" }
        return "?"
    }
}

/// Traces réseau (sans contenu) : `log show --predicate 'subsystem == "fr.anthony.slipway"'`.
let traces = Logger(subsystem: "fr.anthony.slipway", category: "reseau")

/// File réseau unique, priorité maximale : l'injection côté Mac piloté se fait directement depuis elle.
let fileReseau = DispatchQueue(label: "fr.anthony.slipway.reseau", qos: .userInteractive)

/// Canal fiable sur une NWConnection TCP : enregistrements préfixés de leur longueur (u16 petit-boutiste).
final class LienTCP: LienReseau, @unchecked Sendable {
    let connexion: NWConnection
    private let moteur: Moteur
    private let id = Mutex<IdConnexion?>(nil)
    private let ferme = Mutex(false)
    private let canalUDP = Mutex<CanalUDP?>(nil)
    private let surFermeture: @Sendable () -> Void

    init(connexion: NWConnection, moteur: Moteur, surFermeture: @escaping @Sendable () -> Void) {
        self.connexion = connexion
        self.moteur = moteur
        self.surFermeture = surFermeture
    }

    var description: String {
        let distant = connexion.currentPath?.remoteEndpoint.map { "\($0)" } ?? "\(connexion.endpoint)"
        return "\(distant) (\(ParametresReseau.decrire(connexion.currentPath)))"
    }

    func demarrer(role: MaterielSession.Role) {
        // Capture forte voulue : une connexion acceptée n'est retenue par personne avant `.ready` (sans elle, le lien
        // disparaissait aussitôt et l'appairage ne démarrait jamais). Le cycle est rompu dans `terminer()`.
        connexion.stateUpdateHandler = { etat in
            switch etat {
            case .ready:
                let id = self.moteur.connexionOuverte(self, role: role)
                self.id.withLock { $0 = id }
                self.lireEntete()
            case .failed(let erreur):
                traces.notice("Lien \(self.description, privacy: .public) en échec : \(erreur, privacy: .public)")
                self.terminer()
            case .cancelled:
                self.terminer()
            case .waiting(let erreur):
                // Sans cela, une connexion sortante restait en attente indéfiniment et bloquait les nouvelles tentatives.
                traces.notice("Lien \(self.description, privacy: .public) en attente : \(erreur, privacy: .public)")
                self.terminer()
            default:
                break
            }
        }
        connexion.start(queue: fileReseau)
    }

    private func lireEntete() {
        connexion.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] donnees, _, fini, erreur in
            guard let self else { return }
            guard erreur == nil, let donnees, donnees.count == 2 else { self.terminer(); return }
            let longueur = Int(donnees[donnees.startIndex]) | Int(donnees[donnees.startIndex + 1]) << 8
            guard longueur > 0 else { if fini { self.terminer() } else { self.lireEntete() }; return }
            self.lireCorps(longueur)
        }
    }

    private func lireCorps(_ longueur: Int) {
        connexion.receive(minimumIncompleteLength: longueur, maximumLength: longueur) { [weak self] donnees, _, fini, erreur in
            guard let self else { return }
            guard erreur == nil, let donnees, donnees.count == longueur, let id = self.id.withLock({ $0 }) else { self.terminer(); return }
            self.moteur.enregistrementRecu([UInt8](donnees), connexion: id)
            if fini { self.terminer() } else { self.lireEntete() }
        }
    }

    func envoyer(_ enregistrement: [UInt8]) {
        guard enregistrement.count <= Int(UInt16.max) else { return }
        var donnees = Data(capacity: enregistrement.count + 2)
        donnees.append(UInt8(truncatingIfNeeded: enregistrement.count))
        donnees.append(UInt8(truncatingIfNeeded: enregistrement.count >> 8))
        donnees.append(contentsOf: enregistrement)
        connexion.send(content: donnees, completion: .contentProcessed { _ in })
    }

    /// Adresse IPv4 du pair si ce lien passe par IPv4 (mémorisée comme secours de Bonjour).
    var hoteIPv4: String? {
        guard case .hostPort(let hote, _)? = connexion.currentPath?.remoteEndpoint else { return nil }
        let ip: IPv4Address?
        switch hote {
        case .ipv4(let a): ip = a
        case .ipv6(let a): ip = a.asIPv4
        default: ip = nil
        }
        return ip.map { String("\($0)".prefix { $0 != "%" }) }   // sans l'interface (« %en0 »)
    }

    func ouvrirCanalTempsReel(port: UInt16) -> CanalDatagrammes? {
        guard case .hostPort(let hote, _)? = connexion.currentPath?.remoteEndpoint, let p = NWEndpoint.Port(rawValue: port) else { return nil }
        let udp = NWConnection(host: hote, port: p, using: ParametresReseau.udp())
        let canal = CanalUDP(connexion: udp, moteur: moteur)
        canal.demarrer()
        canalUDP.withLock { $0?.fermer(); $0 = canal }
        return canal
    }

    func fermer() {
        connexion.cancel()
    }

    private func terminer() {
        let deja = ferme.withLock { f -> Bool in defer { f = true }; return f }
        guard !deja else { return }
        connexion.stateUpdateHandler = nil
        connexion.cancel()
        canalUDP.withLock { $0?.fermer(); $0 = nil }
        if let id = id.withLock({ $0 }) { moteur.connexionFermee(id) }
        surFermeture()
    }
}

/// Canal temps réel sur une NWConnection UDP (créée par le client, ou par l'écoute UDP côté serveur).
final class CanalUDP: CanalDatagrammes, @unchecked Sendable {
    let connexion: NWConnection
    private let moteur: Moteur
    private let enVol = Mutex(0)
    /// Côté écoute : un canal par adresse source, fermé s'il ne reçoit rien d'authentique (5 s au départ, 30 s ensuite).
    private let ecoute: Bool
    private let dernierAuthentique = Mutex<Date?>(nil)
    private let debut = Date()
    /// Canaux ouverts par l'écoute UDP : plafonnés (des datagrammes à source falsifiée ne doivent pas épuiser la mémoire).
    private static let ouverts = Mutex(0)
    static let maxOuverts = 32

    init(connexion: NWConnection, moteur: Moteur, ecoute: Bool = false) {
        self.connexion = connexion
        self.moteur = moteur
        self.ecoute = ecoute
    }

    func demarrer() {
        if ecoute {
            let accepte = Self.ouverts.withLock { n -> Bool in guard n < Self.maxOuverts else { return false }; n += 1; return true }
            guard accepte else { connexion.cancel(); return }
            surveiller()
        }
        connexion.stateUpdateHandler = { _ in }
        connexion.start(queue: fileReseau)
        recevoir()
    }

    func fermer() { connexion.cancel() }

    private func surveiller() {
        fileReseau.asyncAfter(deadline: .now() + 5) { [self] in
            let dernier = dernierAuthentique.withLock { $0 }
            let silence = Date().timeIntervalSince(dernier ?? debut)
            if silence > (dernier == nil ? 5 : 30) {
                connexion.cancel()
                Self.ouverts.withLock { $0 -= 1 }
            } else {
                surveiller()
            }
        }
    }

    /// La réception en attente retient le canal (référence forte) : côté serveur, personne d'autre ne le garde
    /// tant que le premier datagramme n'est pas authentifié. Le cycle se rompt quand la connexion est annulée
    /// (la réception rend une erreur et n'est pas relancée) : par la surveillance côté écoute, par le lien TCP côté client.
    private func recevoir() {
        connexion.receiveMessage { [self] donnees, _, _, erreur in
            if let donnees, !donnees.isEmpty, self.moteur.datagrammeRecu([UInt8](donnees), retour: self) {
                self.dernierAuthentique.withLock { $0 = Date() }
            }
            if erreur == nil { self.recevoir() }
        }
    }

    func envoyer(_ datagramme: [UInt8]) {
        enVol.withLock { $0 += 1 }
        connexion.send(content: Data(datagramme), completion: .contentProcessed { [weak self] _ in
            self?.enVol.withLock { $0 -= 1 }
        })
    }

    /// Plus de 4 datagrammes en attente d'émission : le Wi-Fi ne suit pas, le moteur fusionne les mouvements.
    var estSature: Bool { enVol.withLock { $0 } > 4 }
}

/// Un Mac Slipway vu sur le réseau local (Bonjour).
public struct MacDecouvert: Equatable, Sendable, Identifiable {
    public var id: IdPair
    public var nom: String
    public var connu: Bool
    let point: NWEndpoint
}

/// Écoute (TCP + UDP), publication et découverte Bonjour, connexions sortantes et reconnexion automatique.
public final class ServiceReseau: @unchecked Sendable {
    private let moteur: Moteur
    private let magasin: MagasinPairsMac
    private let nom: String
    private let surChangement: @Sendable () -> Void

    /// Le Mac au plus petit identifiant reconnecte tout de suite ; l'autre attend ce délai sans lien (si le premier
    /// ne le voit pas sur le réseau). Une connexion croisée est dédoublonnée par le moteur.
    static let attentePlusGrand: TimeInterval = 10
    /// Pair connu sans lien ni découverte depuis ce délai : la recherche Bonjour est relancée.
    static let relanceRecherche: TimeInterval = 30
    static let delaiRelance: TimeInterval = 5
    /// Une tentative sortante qui n'a toujours pas abouti après ce délai est abandonnée (la suivante essaie l'autre chemin).
    static let delaiTentative: TimeInterval = 8

    private struct Etat {
        var actif = false
        var ecouteTCP: NWListener?
        var ecouteUDP: NWListener?
        var navigateur: NWBrowser?
        var navigateurDepuis = Date.distantPast
        var surveillance: NWPathMonitor?
        var reseauPresent = true
        var decouverts: [IdPair: MacDecouvert] = [:]
        var enCours: [IdPair: (lien: LienTCP, depuis: Date)] = [:]
        var backoff: [IdPair: (Backoff, prochain: Date)] = [:]
        var sansLienDepuis: [IdPair: Date] = [:]
        var erreurs: [String] = []
    }
    private let etat = Mutex(Etat())

    public init(moteur: Moteur, magasin: MagasinPairsMac, nom: String, surChangement: @escaping @Sendable () -> Void) {
        self.moteur = moteur
        self.magasin = magasin
        self.nom = nom
        self.surChangement = surChangement
    }

    public var decouverts: [MacDecouvert] { etat.withLock { Array($0.decouverts.values) }.sorted { $0.nom < $1.nom } }
    public var erreurs: [String] { etat.withLock { $0.erreurs } }

    public func demarrer() {
        etat.withLock { $0.actif = true }
        demarrerEcouteTCP()
        demarrerEcouteUDP()
        demarrerNavigateur()
        let surveillance = NWPathMonitor()
        surveillance.pathUpdateHandler = { [weak self] chemin in
            guard let self else { return }
            let present = chemin.status == .satisfied
            let revenu = self.etat.withLock { e in defer { e.reseauPresent = present }; return present && !e.reseauPresent }
            // Le réseau revient (câble rebranché, Wi-Fi retrouvé) : on retente tout de suite et on relance la recherche.
            if revenu {
                self.etat.withLock { $0.backoff.removeAll() }
                self.demarrerNavigateur()
            }
        }
        surveillance.start(queue: fileReseau)
        etat.withLock { $0.surveillance = surveillance }
    }

    public func arreter() {
        let e = etat.withLock { e in defer { e = Etat() }; return e }
        e.ecouteTCP?.cancel(); e.ecouteUDP?.cancel(); e.navigateur?.cancel(); e.surveillance?.cancel()
        for t in e.enCours.values { t.lien.fermer() }
    }

    private func demarrerEcouteTCP() {
        guard etat.withLock({ $0.actif }) else { return }
        do {
            let tcp = try NWListener(using: ParametresReseau.tcp(), on: NWEndpoint.Port(rawValue: PortsSlipway.tcp)!)
            var txt = NWTXTRecord()
            txt["id"] = moteur.moi.rawValue
            txt["v"] = "\(Protocole.versionMajeure)"
            tcp.service = NWListener.Service(name: nom, type: Protocole.serviceBonjour, domain: nil, txtRecord: txt)
            tcp.newConnectionHandler = { [weak self] connexion in self?.accepter(connexion) }
            tcp.stateUpdateHandler = { [weak self, weak tcp] e in
                guard let self, let tcp, case .failed(let erreur) = e else { return }
                tcp.cancel()
                self.relancer("Écoute TCP : \(erreur)") { $0.demarrerEcouteTCP() }
            }
            etat.withLock { $0.ecouteTCP = tcp }
            tcp.start(queue: fileReseau)
        } catch {
            relancer("Écoute TCP impossible : \(error)") { $0.demarrerEcouteTCP() }
        }
    }

    private func demarrerEcouteUDP() {
        guard etat.withLock({ $0.actif }) else { return }
        do {
            let udp = try NWListener(using: ParametresReseau.udp(), on: NWEndpoint.Port(rawValue: PortsSlipway.udp)!)
            udp.newConnectionHandler = { [weak self] connexion in
                guard let self else { return }
                CanalUDP(connexion: connexion, moteur: self.moteur, ecoute: true).demarrer()
            }
            udp.stateUpdateHandler = { [weak self, weak udp] e in
                guard let self, let udp, case .failed(let erreur) = e else { return }
                udp.cancel()
                self.relancer("Écoute UDP : \(erreur)") { $0.demarrerEcouteUDP() }
            }
            etat.withLock { $0.ecouteUDP = udp }
            udp.start(queue: fileReseau)
        } catch {
            relancer("Écoute UDP impossible : \(error)") { $0.demarrerEcouteUDP() }
        }
    }

    /// (Re)lance la recherche Bonjour. En échec ou bloquée (`.waiting`, par exemple réseau local refusé), on le note
    /// et on recommence après un délai : sans cela, un Mac pouvait ne plus jamais voir l'autre.
    private func demarrerNavigateur() {
        let navigateur = NWBrowser(for: .bonjourWithTXTRecord(type: Protocole.serviceBonjour, domain: nil), using: ParametresReseau.tcp())
        navigateur.browseResultsChangedHandler = { [weak self] resultats, _ in self?.resultatsBonjour(resultats) }
        navigateur.stateUpdateHandler = { [weak self, weak navigateur] e in
            guard let self, let navigateur, self.etat.withLock({ $0.navigateur === navigateur }) else { return }
            switch e {
            case .failed(let erreur), .waiting(let erreur):
                navigateur.cancel()
                self.relancer("Recherche Bonjour : \(erreur)") { $0.demarrerNavigateur() }
            default: break
            }
        }
        let ancien: NWBrowser?? = etat.withLock { e in
            guard e.actif else { return .none }
            defer { e.navigateur = navigateur; e.navigateurDepuis = Date() }
            return .some(e.navigateur)
        }
        guard case .some(let precedent) = ancien else { return }
        precedent?.cancel()
        navigateur.start(queue: fileReseau)
    }

    private func relancer(_ erreur: String, _ action: @escaping @Sendable (ServiceReseau) -> Void) {
        noterErreur("\(erreur) (nouvel essai dans \(Int(Self.delaiRelance)) s)")
        fileReseau.asyncAfter(deadline: .now() + Self.delaiRelance) { [weak self] in if let self { action(self) } }
    }

    /// Appairage demandé par l'utilisateur avec un Mac découvert (inconnu jusqu'ici).
    public func appairer(_ mac: MacDecouvert) {
        connecter(mac.point, id: mac.id)
    }

    /// Secours : adresse IP saisie à la main (Bonjour bloqué sur certains réseaux).
    public func connecter(hote: String) {
        connecter(Self.point(hote), id: nil)
    }

    private static func point(_ hote: String) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(hote), port: NWEndpoint.Port(rawValue: PortsSlipway.tcp)!)
    }

    /// À appeler toutes les secondes : reconnexion automatique aux Mac appairés, avec délais progressifs.
    /// Point d'arrivée : l'annonce Bonjour, ou à défaut (une tentative sur deux) la dernière IPv4 qui a marché.
    public func tic() {
        let maintenant = Date()
        let liens = moteur.liensEtablis()
        for (id, lien) in liens {
            if let ip = (lien as? LienTCP)?.hoteIPv4 { magasin.memoriserAdresse(ip, id: id) }
        }
        let connus = magasin.liste.map { (id: $0.id, ip: magasin.adresse(id: $0.id)) }
        var relancerRecherche = false
        // Tentatives bloquées (résolution Bonjour ou connexion qui ne répond pas) : abandonnées.
        let bloquees = etat.withLock { e in
            let ids = e.enCours.filter { liens[$0.key] == nil && maintenant.timeIntervalSince($0.value.depuis) > Self.delaiTentative }.map(\.key)
            return ids.compactMap { e.enCours.removeValue(forKey: $0)?.lien }
        }
        for l in bloquees {
            traces.notice("Tentative abandonnée (sans réponse) : \(l.description, privacy: .public)")
            l.fermer()
        }
        let aConnecter: [(IdPair, NWEndpoint)] = etat.withLock { e in
            connus.compactMap { pair in
                let id = pair.id
                guard liens[id] == nil else { e.backoff[id] = nil; e.sansLienDepuis[id] = nil; return nil }
                let depuis = e.sansLienDepuis[id] ?? maintenant
                e.sansLienDepuis[id] = depuis
                let attente = maintenant.timeIntervalSince(depuis)
                if e.decouverts[id] == nil, attente >= Self.relanceRecherche,
                   maintenant.timeIntervalSince(e.navigateurDepuis) >= Self.relanceRecherche { relancerRecherche = true }
                guard e.enCours[id] == nil, moteur.moi < id || attente >= Self.attentePlusGrand,
                      (e.backoff[id]?.prochain ?? .distantPast) <= maintenant else { return nil }
                var b = e.backoff[id]?.0 ?? Backoff()
                let parIP = b.tentatives % 2 == 1
                let bonjour = e.decouverts[id]?.point, secours = pair.ip.map(Self.point)
                guard let point = parIP ? (secours ?? bonjour) : (bonjour ?? secours) else { return nil }
                let delai = b.prochainDelai()   // avant de ranger `b` : le compteur de tentatives doit avancer
                e.backoff[id] = (b, maintenant.addingTimeInterval(delai))
                return (id, point)
            }
        }
        // Toutes les 10 s, tant qu'un Mac connu n'est pas relié : pourquoi (diagnostic par `log show`).
        if Int(maintenant.timeIntervalSince1970) % 10 == 0, connus.contains(where: { liens[$0.id] == nil }) {
            let resume = etat.withLock { e in
                connus.map { p in
                    "\(p.id): lien \(liens[p.id] != nil), vu \(e.decouverts[p.id] != nil), ip \(p.ip ?? "-"), en cours \(e.enCours[p.id] != nil), "
                        + "sans lien depuis \(Int(maintenant.timeIntervalSince(e.sansLienDepuis[p.id] ?? maintenant))) s"
                }.joined(separator: " ; ")
            }
            traces.notice("Pairs connus (\(connus.count)) : \(resume, privacy: .public) ; moi \(self.moteur.moi, privacy: .public)")
        }
        if relancerRecherche { demarrerNavigateur() }
        for (id, point) in aConnecter { connecter(point, id: id) }
    }

    private func connecter(_ point: NWEndpoint, id: IdPair?) {
        let parametres = ParametresReseau.tcp()
        // Annonce Bonjour : on va en IPv4 (plus stable et moins lent que l'IPv6 lien-local sur le Wi-Fi de la maison).
        if case .service = point, let ip = parametres.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connexion = NWConnection(to: point, using: parametres)
        let lien = LienTCP(connexion: connexion, moteur: moteur) { [weak self] in
            if let id { self?.etat.withLock { _ = $0.enCours.removeValue(forKey: id) } }
            self?.surChangement()
        }
        if let id { etat.withLock { $0.enCours[id] = (lien, Date()) } }
        traces.notice("Connexion sortante vers \(String(describing: point), privacy: .public)")
        lien.demarrer(role: .client)
    }

    private func accepter(_ connexion: NWConnection) {
        // Connexion depuis ce Mac lui-même : jamais un autre Mac, refusée (un programme local ne se fait pas passer pour un pair).
        if case .hostPort(let hote, _) = connexion.endpoint {
            let boucle: Bool
            switch hote {
            case .ipv4(let a): boucle = a.isLoopback
            case .ipv6(let a): boucle = a.isLoopback || a.asIPv4?.isLoopback == true
            default: boucle = false
            }
            if boucle { connexion.cancel(); return }
        }
        let lien = LienTCP(connexion: connexion, moteur: moteur) { [weak self] in self?.surChangement() }
        lien.demarrer(role: .serveur)
    }

    private func resultatsBonjour(_ resultats: Set<NWBrowser.Result>) {
        var trouves: [IdPair: MacDecouvert] = [:]
        for r in resultats {
            guard case .bonjour(let txt) = r.metadata, let brut = txt["id"], brut != moteur.moi.rawValue else { continue }
            let id = IdPair(rawValue: brut)
            var nomMac = brut
            if case .service(let n, _, _, _) = r.endpoint { nomMac = n }
            trouves[id] = MacDecouvert(id: id, nom: nomMac, connu: magasin.estConnu(id: id), point: r.endpoint)
        }
        etat.withLock { $0.decouverts = trouves }
        surChangement()
    }

    private func noterErreur(_ texte: String) {
        traces.error("\(texte, privacy: .public)")
        etat.withLock { e in
            e.erreurs.append(texte)
            if e.erreurs.count > 20 { e.erreurs.removeFirst(e.erreurs.count - 20) }
        }
        surChangement()
    }
}
#endif
