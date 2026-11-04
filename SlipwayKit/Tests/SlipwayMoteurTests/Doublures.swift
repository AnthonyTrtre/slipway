import Synchronization
import SlipwayCoeur
import SlipwaySecurite
@testable import SlipwayMoteur

// Doublures de test : réseau en mémoire (avec pertes paramétrables), injecteur et curseur espions,
// presse-papiers factice, magasin de pairs en mémoire, horloge manuelle.

final class HorlogeTest: Horloge {
    private let t = Mutex(1.0)
    func maintenant() -> Double { t.withLock { $0 } }
    func avancer(_ d: Double) { t.withLock { $0 += d } }
}

final class InjecteurEspion: InjecteurEntrees {
    private let liste = Mutex<[Injection]>([])
    func injecter(_ injection: Injection) { liste.withLock { $0.append(injection) } }
    var injections: [Injection] { liste.withLock { $0 } }
    func vider() { liste.withLock { $0.removeAll() } }
    var mouvements: [Point] { injections.compactMap { if case .mouvement(let p, _, _) = $0 { p } else { nil } } }
}

final class CurseurEspion: CurseurLocal {
    private let liste = Mutex<[String]>([])
    func figer() { liste.withLock { $0.append("figer") } }
    func liberer(a point: Point) { liste.withLock { $0.append("liberer \(point.x),\(point.y)") } }
    var appels: [String] { liste.withLock { $0 } }
}

final class PressePapiersFaux: PressePapiersLocal {
    private let etat = Mutex<(compteur: Int, contenu: ContenuPressePapiers, verifications: Int)>((0, .texte(""), 0))
    func signalerChangementPossible() { etat.withLock { $0.verifications += 1 } }
    func ecrire(_ contenu: ContenuPressePapiers, fini: @escaping @Sendable (Int?) -> Void) {
        fini(etat.withLock { $0.contenu = contenu; $0.compteur += 1; return $0.compteur })
    }
    func copier(_ texte: String) { copier(contenu: .texte(texte)) }
    func copier(contenu: ContenuPressePapiers) { etat.withLock { $0.contenu = contenu; $0.compteur += 1 } }
    var compteur: Int { etat.withLock { $0.compteur } }
    var contenu: ContenuPressePapiers { etat.withLock { $0.contenu } }
    var texte: String { if case .texte(let t) = contenu { t } else { "" } }
    var verifications: Int { etat.withLock { $0.verifications } }
}

final class MagasinMemoire: MagasinPairs {
    private let cles = Mutex<[[UInt8]: String]>([:])
    func estConnu(_ clePublique: [UInt8]) -> Bool { cles.withLock { $0[clePublique] != nil } }
    func memoriser(clePublique: [UInt8], nom: String) { cles.withLock { $0[clePublique] = nom } }
    var nombre: Int { cles.withLock { $0.count } }
}

final class ObservateurCompteur: ObservateurMoteur {
    private let n = Mutex(0)
    func moteurAChange() { n.withLock { $0 += 1 } }
    var appels: Int { n.withLock { $0 } }
}

/// Réseau simulé : les envois sont mis en file (jamais livrés pendant l'appel, comme un vrai réseau) puis livrés par `pomper()`.
final class ReseauSimule: Sendable {
    enum Livraison {
        case enregistrement([UInt8], Moteur, IdConnexion)
        case datagramme([UInt8], Moteur, CanalTest)
        case fermeture(Moteur, IdConnexion)
    }

    private let file = Mutex<[Livraison]>([])
    /// Probabilité de perte d'un datagramme (0…1), tirage déterministe.
    let perteUDP = Mutex(0.0)
    let udpBloque = Mutex(false)
    private let alea = Mutex<UInt64>(0x1234_5678)

    func enfiler(_ l: Livraison) { file.withLock { $0.append(l) } }

    func perdre() -> Bool {
        let p = perteUDP.withLock { $0 }
        guard p > 0 else { return false }
        let tirage = alea.withLock { e -> Double in
            e ^= e << 13; e ^= e >> 7; e ^= e << 17
            return Double(e % 10_000) / 10_000
        }
        return tirage < p
    }

    /// Livre tout ce qui est en file, y compris ce que les livraisons provoquent.
    func pomper(maximum: Int = 100_000) {
        for _ in 0..<maximum {
            guard let l = file.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { return }
            switch l {
            case .enregistrement(let o, let m, let id): m.enregistrementRecu(o, connexion: id)
            case .datagramme(let o, let m, let retour): m.datagrammeRecu(o, retour: retour)
            case .fermeture(let m, let id): m.connexionFermee(id)
            }
        }
    }
}

final class CanalTest: CanalDatagrammes {
    let reseau: ReseauSimule
    let nom: String
    private let cible = Mutex<(Moteur, CanalTest)?>(nil)
    let sature = Mutex(false)
    let envoyes = Mutex(0)

    init(reseau: ReseauSimule, nom: String) { self.reseau = reseau; self.nom = nom }
    func relier(a moteur: Moteur, retour: CanalTest) { cible.withLock { $0 = (moteur, retour) } }

    func envoyer(_ datagramme: [UInt8]) {
        envoyes.withLock { $0 += 1 }
        guard !reseau.udpBloque.withLock({ $0 }), !reseau.perdre(), let (m, retour) = cible.withLock({ $0 }) else { return }
        reseau.enfiler(.datagramme(datagramme, m, retour))
    }
    var estSature: Bool { sature.withLock { $0 } }
}

final class LienTest: LienReseau {
    let reseau: ReseauSimule
    let description: String
    private let cible = Mutex<(Moteur, IdConnexion)?>(nil)
    /// Canal UDP créé côté client et son retour (côté serveur), pour inspection.
    let canal = Mutex<CanalTest?>(nil)
    let ferme = Mutex(false)
    let enregistrements = Mutex<[[UInt8]]>([])
    nonisolated(unsafe) var moteurServeur: Moteur?

    init(reseau: ReseauSimule, description: String) { self.reseau = reseau; self.description = description }
    func relier(a moteur: Moteur, connexion: IdConnexion) { cible.withLock { $0 = (moteur, connexion) } }

    func envoyer(_ enregistrement: [UInt8]) {
        enregistrements.withLock { $0.append(enregistrement) }
        guard !ferme.withLock({ $0 }), let (m, id) = cible.withLock({ $0 }) else { return }
        reseau.enfiler(.enregistrement(enregistrement, m, id))
    }

    func ouvrirCanalTempsReel(port: UInt16) -> CanalDatagrammes? {
        guard let serveur = moteurServeur, let client = clientMoteur else { return nil }
        let aller = CanalTest(reseau: reseau, nom: "\(description) UDP aller")
        let retour = CanalTest(reseau: reseau, nom: "\(description) UDP retour")
        aller.relier(a: serveur, retour: retour)
        retour.relier(a: client, retour: aller)
        canal.withLock { $0 = aller }
        return aller
    }
    nonisolated(unsafe) var clientMoteur: Moteur?

    func fermer() {
        let deja = ferme.withLock { f -> Bool in defer { f = true }; return f }
        guard !deja, let (m, id) = cible.withLock({ $0 }) else { return }
        reseau.enfiler(.fermeture(m, id))
    }
}

/// Un Mac simulé complet : moteur + toutes ses doublures.
struct MacSimule {
    let moteur: Moteur
    let injecteur = InjecteurEspion()
    let curseur = CurseurEspion()
    let pressePapiers = PressePapiersFaux()
    let magasin = MagasinMemoire()
    let observateur = ObservateurCompteur()
    let horloge: HorlogeTest
    let identite: Identite

    init(nom: String, graine: UInt8, ecrans: [Ecran], horloge: HorlogeTest, capacites: Capacites = .toutes) {
        self.horloge = horloge
        identite = try! Identite(brut: (0..<32).map { UInt8($0) &+ graine })
        let config = ConfigurationMoteur(identite: identite, nom: nom, capacites: capacites, portUDP: 24851, ecransLocaux: ecrans)
        moteur = Moteur(config: config, horloge: horloge, injecteur: injecteur, curseur: curseur, pressePapiers: pressePapiers,
                        magasin: magasin, observateur: observateur)
    }

    var id: IdPair { identite.id }
}

/// Deux Mac reliés : A (client réseau) à gauche, B (serveur réseau) à droite.
struct Banc {
    let reseau = ReseauSimule()
    let horloge = HorlogeTest()
    let a: MacSimule
    let b: MacSimule
    var lienA: LienTest!
    var lienB: LienTest!

    init(appairesDAvance: Bool = true, capacitesB: Capacites = .toutes) {
        a = MacSimule(nom: "A", graine: 1, ecrans: [Ecran(id: 1, cadre: Rect(x: 0, y: 0, largeur: 1512, hauteur: 982), principal: true)], horloge: horloge)
        b = MacSimule(nom: "B", graine: 101, ecrans: [Ecran(id: 1, cadre: Rect(x: 0, y: 0, largeur: 1920, hauteur: 1080), principal: true)], horloge: horloge,
                      capacites: capacitesB)
        if appairesDAvance {
            a.magasin.memoriser(clePublique: b.identite.clePublique, nom: "B")
            b.magasin.memoriser(clePublique: a.identite.clePublique, nom: "A")
        } else {
            a.moteur.ouvrirAppairage()
            b.moteur.ouvrirAppairage()
        }
    }

    /// Ouvre la connexion A → B et pompe la poignée de main.
    @discardableResult
    mutating func connecter() -> (IdConnexion, IdConnexion) {
        lienA = LienTest(reseau: reseau, description: "A→B")
        lienB = LienTest(reseau: reseau, description: "B→A")
        lienA.moteurServeur = b.moteur
        lienA.clientMoteur = a.moteur
        let idB = b.moteur.connexionOuverte(lienB, role: .serveur)
        lienA.relier(a: b.moteur, connexion: idB)
        let idA = a.moteur.connexionOuverte(lienA, role: .client)
        lienB.relier(a: a.moteur, connexion: idA)
        reseau.pomper()
        return (idA, idB)
    }

    func tic(_ dt: Double = 0.05) {
        horloge.avancer(dt)
        a.moteur.tic()
        b.moteur.tic()
        reseau.pomper()
    }

    /// Pousse la souris d'A au-delà de son bord droit.
    func passerSurB() -> Bool {
        let avale = a.moteur.evenementLocal(.mouvement(position: Point(x: 1511, y: 400), delta: Point(x: 5, y: 0)))
        reseau.pomper()
        return avale
    }
}
