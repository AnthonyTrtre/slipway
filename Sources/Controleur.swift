import AppKit
import Observation
import SocleCore
import Synchronization
import SlipwayCoeur
import SlipwaySecurite
import SlipwayMoteur
import SlipwayMac

/// Relie le moteur (pur) aux adaptateurs macOS et expose l'état à SwiftUI. Tout ce qui est ici vit sur le fil
/// principal ; le chemin chaud (capture → moteur → réseau → injection) ne passe jamais par lui.
@MainActor
@Observable
final class Controleur {
    private(set) var instantane: Instantane?
    private(set) var decouverts: [MacDecouvert] = []
    private(set) var erreurDemarrage: String?
    private(set) var permissionsOK = Permissions.toutes
    /// Rôle de ce Mac, mémorisé : principal par défaut. Changé ici, l'autre Mac prend le rôle inverse (et réciproquement).
    private(set) var principal: Bool = UserDefaults.standard.object(forKey: "principal") as? Bool ?? true {
        didSet { UserDefaults.standard.set(principal, forKey: "principal") }
    }
    private(set) var saisieSecurisee: String?
    private(set) var captureActive = false
    private(set) var reactivationsTap = 0
    private(set) var erreursReseau: [String] = []
    private(set) var nomMac = Host.current().localizedName ?? "Mac"

    @ObservationIgnored private var moteur: Moteur?
    @ObservationIgnored private var capture: CaptureEvenements?
    @ObservationIgnored private var reseau: ServiceReseau?
    @ObservationIgnored private let curseur = CurseurMac()
    @ObservationIgnored private let magasin = MagasinPairsMac()
    @ObservationIgnored private var minuteurMoteur: DispatchSourceTimer?
    @ObservationIgnored private var minuteurVidage: DispatchSourceTimer?
    @ObservationIgnored private var minuteurLent: Timer?
    @ObservationIgnored private var observateurs: [NSObjectProtocol] = []
    /// Tant qu'un autre Mac est relié, ce Mac ne s'endort pas de lui-même (l'écran peut s'éteindre) : endormi, il
    /// quitterait le Wi-Fi et la souris ne pourrait plus y passer.
    @ObservationIgnored private var activiteEveil: NSObjectProtocol?

    static let cleDisposition = "disposition"
    static var sousTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    init() {
        guard !Self.sousTest else { return }   // l'app sert d'hôte aux tests : ni capture ni réseau
        demarrer()
    }

    // MARK: - Démarrage

    private func demarrer() {
        let identite: Identite
        do { identite = try Trousseau.chargerOuCreerIdentite() } catch {
            erreurDemarrage = "Trousseau inaccessible : \(error)"
            Journal.app.error("Slipway : trousseau inaccessible (\(String(describing: error), privacy: .public))")
            return
        }
        var disposition = Disposition()
        if let data = UserDefaults.standard.data(forKey: Self.cleDisposition),
           let d = try? JSONDecoder().decode(Disposition.self, from: data) { disposition = d }

        let pressePapiers = PressePapiersMac()
        let observateur = ObservateurApp { [weak self] in self?.rafraichir() }
        let config = ConfigurationMoteur(identite: identite, nom: nomMac, portUDP: PortsSlipway.udp,
                                         ecransLocaux: EcransMac.lister(), disposition: disposition)
        let moteur = Moteur(config: config, injecteur: InjecteurMac(), curseur: curseur, pressePapiers: pressePapiers,
                            magasin: magasin, observateur: observateur)
        pressePapiers.relier { [moteur] compteur, lire in moteur.compteurPressePapiers(compteur, lire: lire) }
        moteur.definirPrincipal(principal)
        self.moteur = moteur

        let reseau = ServiceReseau(moteur: moteur, magasin: magasin, nom: nomMac, surChangement: observateur.signaler)
        reseau.demarrer()
        self.reseau = reseau

        // Battements de cœur, liens perdus, mouvements fusionnés : toutes les 50 ms, hors du fil principal.
        let minuteur = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        minuteur.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        minuteur.setEventHandler { @Sendable [moteur] in moteur.tic() }  // hors du fil principal : jamais isolée au MainActor
        minuteur.resume()
        minuteurMoteur = minuteur
        // Mouvements de souris fusionnés : partis au plus tard 4 ms après le précédent.
        let vidage = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        vidage.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        vidage.setEventHandler { @Sendable [moteur] in moteur.viderMouvements() }
        vidage.resume()
        minuteurVidage = vidage

        minuteurLent = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticLent() }
        }
        observerLeSysteme()
        demarrerCapture()
        rafraichir()
    }

    /// Lance la capture si les autorisations sont là (sinon, on réessaie à chaque tic lent).
    private func demarrerCapture() {
        guard capture == nil, let moteur, Permissions.toutes else { return }
        let c = CaptureEvenements(apresMouvementAvale: { [curseur] in curseur.maintenir() }) { [moteur] evenement in
            moteur.evenementLocal(evenement)
        }
        if c.demarrer() { capture = c }
    }

    private func ticLent() {
        permissionsOK = Permissions.toutes
        demarrerCapture()
        saisieSecurisee = SaisieSecurisee.active ? (SaisieSecurisee.applicationResponsable ?? "une application") : nil
        captureActive = capture?.estActive ?? false
        reactivationsTap = capture?.reactivations ?? 0
        reseau?.tic()
        rafraichir()
    }

    func rafraichir() {
        guard let moteur else { return }
        let nouveau = moteur.instantane()
        if nouveau.disposition != instantane?.disposition, let data = try? JSONEncoder().encode(nouveau.disposition) {
            UserDefaults.standard.set(data, forKey: Self.cleDisposition)
        }
        instantane = nouveau
        let relie = !nouveau.pairs.isEmpty
        if relie, activiteEveil == nil {
            activiteEveil = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Slipway : un autre Mac est relié")
        } else if !relie, let a = activiteEveil {
            ProcessInfo.processInfo.endActivity(a)
            activiteEveil = nil
        }
        if nouveau.principal != principal { principal = nouveau.principal }   // changé depuis l'autre Mac
        decouverts = reseau?.decouverts ?? []
        erreursReseau = reseau?.erreurs ?? []
    }

    private func observerLeSysteme() {
        let ws = NSWorkspace.shared.notificationCenter
        // Avant la veille, au verrouillage, au changement d'utilisateur : tout revient en local, rien ne reste enfoncé.
        for nom in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observateurs.append(ws.addObserver(forName: nom, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.moteur?.toutRendreLocal(raison: .veille) }
            })
        }
        observateurs.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moteur?.toutRendreLocal(raison: .veille) }
        })
        observateurs.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.moteur?.ecransLocauxChanges(EcransMac.lister()) }
        })
    }

    // MARK: - Commandes de l'interface

    func toutRendreLocal() { moteur?.toutRendreLocal(raison: .panique) }
    func choisirPrincipal(_ oui: Bool) { principal = oui; moteur?.definirPrincipal(oui, propager: true); rafraichir() }
    func basculer(vers id: IdPair) { moteur?.basculerVers(id) }
    func confirmerAppairage(_ id: IdConnexion, accepte: Bool) { moteur?.confirmerAppairage(id, accepte: accepte) }
    /// Appairer ou connecter à la main ouvre aussi l'appairage ici (un Mac inconnu n'est accepté qu'ainsi).
    func appairer(_ mac: MacDecouvert) { moteur?.ouvrirAppairage(); reseau?.appairer(mac) }
    func connecter(hote: String) { moteur?.ouvrirAppairage(); reseau?.connecter(hote: hote.trimmingCharacters(in: .whitespaces)) }
    func ouvrirAppairage(_ oui: Bool) { moteur?.ouvrirAppairage(oui); rafraichir() }
    func modifierDisposition(_ d: Disposition) { moteur?.modifierDisposition(d); rafraichir() }
    func oublier(_ id: IdPair) { magasin.oublier(id: id); rafraichir() }
    func demanderPermissions() { Permissions.demander() }

    var macsAppaires: [(id: IdPair, nom: String)] { magasin.liste }

    /// Filet de sécurité à la fermeture : rien d'enfoncé chez les pairs, curseur visible et libre.
    func arreter() {
        moteur?.toutRendreLocal(raison: .arret)
        capture?.arreter()
        curseur.restaurer()
        minuteurMoteur?.cancel()
        minuteurVidage?.cancel()
        reseau?.arreter()
    }
}

/// Prévenu depuis n'importe quel fil ; regroupe les notifications et rafraîchit l'interface au plus 20 fois par seconde.
final class ObservateurApp: ObservateurMoteur {
    private let enAttente = Mutex(false)
    private let action: @MainActor @Sendable () -> Void

    init(action: @escaping @MainActor @Sendable () -> Void) { self.action = action }

    func moteurAChange() {
        let deja = enAttente.withLock { e -> Bool in defer { e = true }; return e }
        guard !deja else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            enAttente.withLock { $0 = false }
            MainActor.assumeIsolated { action() }
        }
    }

    var signaler: @Sendable () -> Void { { [self] in moteurAChange() } }
}
