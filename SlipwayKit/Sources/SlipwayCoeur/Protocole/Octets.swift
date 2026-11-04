/// Lecture et écriture binaire petit-boutiste, sans dépendance et sans allocation cachée.
/// Toutes les valeurs multi-octets du protocole Slipway sont en petit-boutiste (little-endian).

public enum ErreurDecodage: Error, Equatable, Sendable {
    case tronque(attendu: Int, restant: Int)
    case magiqueInvalide
    case texteInvalide
    case valeurInvalide(String)
    case versionIncompatible(majeure: UInt8)
    case longueurIncoherente(annoncee: Int, reelle: Int)
}

public struct EcrivainOctets: Sendable {
    public private(set) var octets: [UInt8]

    public init(capacite: Int = 64) {
        octets = []
        octets.reserveCapacity(capacite)
    }

    public mutating func u8(_ v: UInt8) { octets.append(v) }
    public mutating func booleen(_ v: Bool) { octets.append(v ? 1 : 0) }

    public mutating func u16(_ v: UInt16) {
        octets.append(UInt8(truncatingIfNeeded: v))
        octets.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    public mutating func u32(_ v: UInt32) {
        for decalage in stride(from: 0, to: 32, by: 8) { octets.append(UInt8(truncatingIfNeeded: v >> UInt32(decalage))) }
    }

    public mutating func u64(_ v: UInt64) {
        for decalage in stride(from: 0, to: 64, by: 8) { octets.append(UInt8(truncatingIfNeeded: v >> UInt64(decalage))) }
    }

    public mutating func f32(_ v: Float) { u32(v.bitPattern) }

    public mutating func brut<S: Sequence>(_ s: S) where S.Element == UInt8 { octets.append(contentsOf: s) }

    /// Texte UTF-8 précédé de sa longueur sur un octet ; tronqué proprement (jamais au milieu d'un caractère).
    public mutating func texteCourt(_ texte: String, maximum: Int = 255) {
        let tronque = Self.tronquerUTF8(texte, maximum: min(maximum, 255))
        u8(UInt8(tronque.count))
        brut(tronque)
    }

    /// Texte UTF-8 précédé de sa longueur sur deux octets.
    public mutating func texteLong(_ texte: String, maximum: Int = 1024) {
        let tronque = Self.tronquerUTF8(texte, maximum: min(maximum, Int(UInt16.max)))
        u16(UInt16(tronque.count))
        brut(tronque)
    }

    static func tronquerUTF8(_ texte: String, maximum: Int) -> [UInt8] {
        var resultat: [UInt8] = []
        for scalaire in texte.unicodeScalars {
            let encode = Array(String(scalaire).utf8)
            if resultat.count + encode.count > maximum { break }
            resultat.append(contentsOf: encode)
        }
        return resultat
    }
}

public struct LecteurOctets: Sendable {
    public let octets: [UInt8]
    public private(set) var position: Int

    public init(_ octets: [UInt8], position: Int = 0) {
        self.octets = octets
        self.position = position
    }

    public var restant: Int { octets.count - position }
    public var estFini: Bool { restant == 0 }

    mutating func exiger(_ n: Int) throws(ErreurDecodage) {
        guard restant >= n else { throw .tronque(attendu: n, restant: restant) }
    }

    public mutating func u8() throws(ErreurDecodage) -> UInt8 {
        try exiger(1)
        defer { position += 1 }
        return octets[position]
    }

    public mutating func booleen() throws(ErreurDecodage) -> Bool {
        let v = try u8()
        guard v <= 1 else { throw .valeurInvalide("booléen \(v)") }
        return v == 1
    }

    public mutating func u16() throws(ErreurDecodage) -> UInt16 {
        try exiger(2)
        defer { position += 2 }
        return UInt16(octets[position]) | UInt16(octets[position + 1]) << 8
    }

    public mutating func u32() throws(ErreurDecodage) -> UInt32 {
        try exiger(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(octets[position + i]) << UInt32(8 * i) }
        position += 4
        return v
    }

    public mutating func u64() throws(ErreurDecodage) -> UInt64 {
        try exiger(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(octets[position + i]) << UInt64(8 * i) }
        position += 8
        return v
    }

    public mutating func f32() throws(ErreurDecodage) -> Float {
        let v = Float(bitPattern: try u32())
        guard v.isFinite else { throw .valeurInvalide("flottant non fini") }
        return v
    }

    public mutating func brut(_ n: Int) throws(ErreurDecodage) -> [UInt8] {
        try exiger(n)
        defer { position += n }
        return Array(octets[position..<(position + n)])
    }

    public mutating func toutLeReste() -> [UInt8] {
        defer { position = octets.count }
        return Array(octets[position...])
    }

    public mutating func texteCourt() throws(ErreurDecodage) -> String {
        let n = Int(try u8())
        return try texte(n)
    }

    public mutating func texteLong() throws(ErreurDecodage) -> String {
        let n = Int(try u16())
        return try texte(n)
    }

    private mutating func texte(_ n: Int) throws(ErreurDecodage) -> String {
        let brut = try self.brut(n)
        guard let s = String(validating: brut, as: UTF8.self) else { throw .texteInvalide }
        return s
    }
}

/// Conversion hexadécimale (fichiers de référence, journaux de diagnostic).
public enum Hex {
    public static func encoder(_ octets: [UInt8]) -> String {
        let chiffres = Array("0123456789abcdef".utf8)
        var sortie: [UInt8] = []
        sortie.reserveCapacity(octets.count * 2)
        for o in octets {
            sortie.append(chiffres[Int(o >> 4)])
            sortie.append(chiffres[Int(o & 0x0F)])
        }
        return String(decoding: sortie, as: UTF8.self)
    }

    /// Décode du texte hexadécimal ; ignore les espaces, retours à la ligne et les commentaires `# …` jusqu'à la fin de ligne.
    public static func decoder(_ texte: String) -> [UInt8]? {
        var quartets: [UInt8] = []
        var dansCommentaire = false
        for c in texte.utf8 {
            if dansCommentaire {
                if c == UInt8(ascii: "\n") { dansCommentaire = false }
                continue
            }
            switch c {
            case UInt8(ascii: "#"): dansCommentaire = true
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"): continue
            case UInt8(ascii: "0")...UInt8(ascii: "9"): quartets.append(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): quartets.append(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): quartets.append(c - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }
        guard quartets.count % 2 == 0 else { return nil }
        return stride(from: 0, to: quartets.count, by: 2).map { quartets[$0] << 4 | quartets[$0 + 1] }
    }
}
