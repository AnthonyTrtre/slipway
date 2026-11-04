/// Délais de reconnexion : 0,25 s, 0,5 s, 1 s, 2 s, 4 s puis 5 s (plafond). Remis à zéro au premier succès.
public struct Backoff: Equatable, Sendable {
    public let initial: Double
    public let plafond: Double
    public private(set) var tentatives = 0

    public init(initial: Double = 0.25, plafond: Double = 5) { self.initial = initial; self.plafond = plafond }

    public mutating func prochainDelai() -> Double {
        defer { tentatives += 1 }
        let d = initial * Double(1 << min(tentatives, 20))
        return min(d, plafond)
    }

    public mutating func reussite() { tentatives = 0 }
}

/// Journal circulaire de taille fixe (les 200 derniers événements de session dans la fenêtre de diagnostic).
public struct JournalCirculaire<Element: Sendable>: Sendable {
    public let capacite: Int
    private var tampon: [Element] = []
    private var debut = 0

    public init(capacite: Int) {
        precondition(capacite > 0)
        self.capacite = capacite
        tampon.reserveCapacity(capacite)
    }

    public mutating func ajouter(_ e: Element) {
        if tampon.count < capacite { tampon.append(e) } else {
            tampon[debut] = e
            debut = (debut + 1) % capacite
        }
    }

    /// Du plus ancien au plus récent.
    public var elements: [Element] { Array(tampon[debut...] + tampon[..<debut]) }
    public var count: Int { tampon.count }
}

/// Statistiques de latence sur une fenêtre glissante d'aller-retours (secondes).
public struct StatistiquesLatence: Sendable {
    private var echantillons: JournalCirculaire<Double>
    public private(set) var total = 0

    public init(fenetre: Int = 512) { echantillons = JournalCirculaire(capacite: fenetre) }

    public mutating func ajouter(allerRetour: Double) {
        guard allerRetour.isFinite, allerRetour >= 0 else { return }
        echantillons.ajouter(allerRetour)
        total += 1
    }

    public var nombre: Int { echantillons.count }
    public var derniere: Double? { echantillons.elements.last }

    public var moyenne: Double? {
        let e = echantillons.elements
        return e.isEmpty ? nil : e.reduce(0, +) / Double(e.count)
    }

    /// Centile `p` (0…100) par la méthode du rang le plus proche.
    public func centile(_ p: Double) -> Double? {
        let tries = echantillons.elements.sorted()
        guard !tries.isEmpty else { return nil }
        let rang = Int((p / 100 * Double(tries.count)).rounded(.up))
        return tries[min(max(rang - 1, 0), tries.count - 1)]
    }

    /// Gigue : moyenne des écarts absolus entre aller-retours consécutifs (à la manière de RFC 3550).
    public var gigue: Double? {
        let e = echantillons.elements
        guard e.count >= 2 else { return nil }
        var somme = 0.0
        for i in 1..<e.count { somme += abs(e[i] - e[i - 1]) }
        return somme / Double(e.count - 1)
    }
}

/// Comptage des datagrammes perdus ou arrivés dans le désordre, à partir des numéros de séquence.
public struct CompteurPertes: Equatable, Sendable {
    public private(set) var recus = 0
    public private(set) var perdus = 0
    public private(set) var desordonnes = 0
    private var plusGrande: UInt32?

    public init() {}

    public mutating func noter(_ sequence: UInt32) {
        recus += 1
        guard let max = plusGrande else { plusGrande = sequence; return }
        if Sequence32.plusRecent(sequence, que: max) {
            let ecart = Int(sequence &- max)
            if ecart > 1 { perdus += min(ecart - 1, 1 << 16) }
            plusGrande = sequence
        } else {
            desordonnes += 1
            if perdus > 0 { perdus -= 1 }   // arrivé en retard : il n'était pas perdu
        }
    }

    /// Taux de pertes (0…1).
    public var taux: Double { recus + perdus == 0 ? 0 : Double(perdus) / Double(recus + perdus) }
}

/// Fusion des mouvements en attente quand le réseau ne suit pas (Wi-Fi saturé) : au lieu d'empiler une file
/// (qui rejouerait des positions périmées en rafale), on additionne les déplacements et on garde la dernière position.
public struct FusionMouvements: Equatable, Sendable {
    private var enAttente: Mouvement?
    public private(set) var fusions = 0

    public init() {}

    public mutating func ajouter(_ m: Mouvement) {
        if var a = enAttente {
            a.dx += m.dx; a.dy += m.dy
            a.x = m.x; a.y = m.y; a.boutons = m.boutons
            enAttente = a
            fusions += 1
        } else {
            enAttente = m
        }
    }

    public mutating func prendre() -> Mouvement? {
        defer { enAttente = nil }
        return enAttente
    }

    public var estVide: Bool { enAttente == nil }
}

/// Empreinte FNV-1a 64 bits (déduplication du presse-papiers ; pas un usage de sécurité).
public enum Empreinte {
    public static func fnv1a(_ octets: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for o in octets {
            h ^= UInt64(o)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}
