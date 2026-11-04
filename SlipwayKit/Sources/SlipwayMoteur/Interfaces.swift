import SlipwayCoeur

/// Interfaces vers le système. Les adaptateurs macOS (SlipwayMac) les implémentent ; les tests utilisent des
/// doublures en mémoire. Un futur client Windows réécrira seulement ces adaptateurs.
///
/// Règle impérative : aucune de ces méthodes ne doit rappeler le moteur de façon synchrone (le moteur les appelle
/// parfois sous son verrou). Les envois réseau doivent être non bloquants (mise en file).

/// Horloge monotone en secondes.
public protocol Horloge: Sendable {
    func maintenant() -> Double
}

/// Lien fiable (TCP) vers un pair. `envoyer` reçoit un enregistrement complet ; l'adaptateur le préfixe de sa
/// longueur sur 2 octets petit-boutistes (voir docs/protocole.md).
public protocol LienReseau: AnyObject, Sendable {
    func envoyer(_ enregistrement: [UInt8])
    /// Côté client : ouvre le canal temps réel (UDP) vers le même hôte, sur le port annoncé par le serveur.
    func ouvrirCanalTempsReel(port: UInt16) -> CanalDatagrammes?
    func fermer()
    /// Description lisible (adresse, interface) pour le diagnostic.
    var description: String { get }
}

/// Canal temps réel (UDP) vers un pair.
public protocol CanalDatagrammes: AnyObject, Sendable {
    func envoyer(_ datagramme: [UInt8])
    /// Vrai si des envois précédents ne sont pas encore partis (réseau saturé) : le moteur fusionne alors les mouvements.
    var estSature: Bool { get }
}

/// Injection d'événements sur ce Mac (CGEventPost).
public protocol InjecteurEntrees: Sendable {
    func injecter(_ injection: Injection)
}

/// Curseur local (blocage pendant le pilotage d'un autre Mac).
public protocol CurseurLocal: Sendable {
    func figer()
    func liberer(a point: Point)
}

/// Presse-papiers local. `signalerChangementPossible` doit, de façon asynchrone, rappeler
/// `Moteur.compteurPressePapiers(_:lire:)` avec le compteur de changements courant.
public protocol PressePapiersLocal: Sendable {
    func signalerChangementPossible()
    /// Écrit le texte et rend le nouveau compteur de changements.
    func ecrire(texte: String) -> Int
}

/// Pairs appairés : on mémorise leur clé publique d'identité (épinglage).
public protocol MagasinPairs: Sendable {
    func estConnu(_ clePublique: [UInt8]) -> Bool
    func memoriser(clePublique: [UInt8], nom: String)
}

/// Prévenu (depuis n'importe quel fil) quand l'état visible change ; l'interface relit alors `Moteur.instantane()`.
public protocol ObservateurMoteur: Sendable {
    func moteurAChange()
}

// MARK: - Implémentations triviales

public struct HorlogeSysteme: Horloge {
    private let debut = ContinuousClock.now
    public init() {}
    public func maintenant() -> Double {
        let d = ContinuousClock.now - debut
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}

public struct SansEffet: InjecteurEntrees, CurseurLocal, PressePapiersLocal, ObservateurMoteur {
    public init() {}
    public func injecter(_ injection: Injection) {}
    public func figer() {}
    public func liberer(a point: Point) {}
    public func signalerChangementPossible() {}
    public func ecrire(texte: String) -> Int { 0 }
    public func moteurAChange() {}
}
