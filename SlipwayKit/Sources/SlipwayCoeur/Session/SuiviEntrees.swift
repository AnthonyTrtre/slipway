/// Suivi de tout ce qui a été enfoncé par injection sur ce Mac, pour pouvoir **tout relâcher** à la bascule,
/// à la perte du lien, à la veille ou sur demande. Invariant : après `toutRelacher()`, rien n'est enfoncé.
public struct SuiviInjections: Equatable, Sendable {
    public private(set) var touches: Set<UInt16> = []
    public private(set) var boutons: Set<BoutonSouris> = []
    public private(set) var touchesSysteme: Set<UInt16> = []
    public private(set) var modificateurs: Modificateurs = []

    public init() {}

    public var estVide: Bool { touches.isEmpty && boutons.isEmpty && touchesSysteme.isEmpty }

    public mutating func noter(_ injection: Injection) {
        switch injection {
        case .touche(let usage, let enfonce, _, let mods):
            if enfonce { touches.insert(usage) } else { touches.remove(usage) }
            modificateurs = mods
        case .bouton(let b, let enfonce, _, _):
            if enfonce { boutons.insert(b) } else { boutons.remove(b) }
        case .toucheSysteme(let t):
            if t.enfonce { touchesSysteme.insert(t.usage) } else { touchesSysteme.remove(t.usage) }
        case .mouvement, .defilement:
            break
        }
    }

    /// Les relâchements à injecter, dans un ordre sûr : boutons, touches ordinaires, puis modificateurs.
    public mutating func toutRelacher(position: Point) -> [Injection] {
        var sortie: [Injection] = []
        for b in boutons.sorted() { sortie.append(.bouton(b, enfonce: false, nbClics: 1, position: position)) }
        let ordinaires = touches.filter { !CodeTouche.estModificateur($0) }.sorted()
        let mods = touches.filter { CodeTouche.estModificateur($0) }.sorted()
        var restant = modificateurs
        for u in ordinaires { sortie.append(.touche(usage: u, enfonce: false, repetition: false, modificateurs: restant)) }
        for u in mods {
            if let m = Modificateurs.pourUsage(u) { restant.remove(m) }
            sortie.append(.touche(usage: u, enfonce: false, repetition: false, modificateurs: restant))
        }
        for u in touchesSysteme.sorted() { sortie.append(.toucheSysteme(ToucheSysteme(usage: u, enfonce: false, repetition: false))) }
        self = SuiviInjections()
        return sortie
    }
}

/// Destination d'une touche enfoncée côté Mac qui capture : son relâchement doit aller au même endroit.
public enum Destination: Equatable, Hashable, Sendable {
    case local
    case pair(IdPair)
}

/// Comparaison de numéros de séquence 32 bits avec bouclage (arithmétique des numéros de série, RFC 1982).
public enum Sequence32 {
    /// Vrai si `a` est strictement plus récent que `b`.
    public static func plusRecent(_ a: UInt32, que b: UInt32) -> Bool { a != b && (a &- b) < 0x8000_0000 }
}
