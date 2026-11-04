import Foundation
import Testing
@testable import SlipwayCoeur

/// Octets de référence : `apps/slipway/docs/octets-de-reference/*.hex`.
/// Ces fichiers sont le contrat binaire pour toute autre implémentation (futur client Windows) :
/// encoder chaque exemple doit donner exactement ces octets, et les décoder doit redonner l'exemple.
/// Pour les régénérer après un changement VOULU du protocole : `SLIPWAY_REGENERER=1 swift test`.
enum FichiersDeReference {
    static var dossier: URL {
        URL(fileURLWithPath: #filePath)   // …/apps/slipway/SlipwayKit/Tests/SlipwayCoeurTests/ce-fichier.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/octets-de-reference")
    }

    static var regenerer: Bool { ProcessInfo.processInfo.environment["SLIPWAY_REGENERER"] == "1" }

    /// Texte du fichier : commentaires `#` puis l'hexadécimal par lignes de 16 octets.
    static func formater(titre: String, description: String, octets: [UInt8], separerEntete: Bool = true) -> String {
        var lignes = ["# Slipway, protocole v1 : \(titre)", "# \(description)", "# \(octets.count) octets"]
        var reste = octets[...]
        if separerEntete, octets.count >= 8 {
            let e = Array(octets.prefix(8))
            lignes.append("# en-tête : type 0x\(Hex.encoder([e[0]])), drapeaux \(e[1]), longueur \(Int(e[2]) | Int(e[3]) << 8), séquence \(Int(e[4]) | Int(e[5]) << 8 | Int(e[6]) << 16 | Int(e[7]) << 24)")
            lignes.append(groupes(e))
            reste = reste.dropFirst(8)
            if !reste.isEmpty { lignes.append("# charge") }
        }
        while !reste.isEmpty {
            lignes.append(groupes(Array(reste.prefix(16))))
            reste = reste.dropFirst(16)
        }
        return lignes.joined(separator: "\n") + "\n"
    }

    static func groupes(_ o: [UInt8]) -> String { o.map { Hex.encoder([$0]) }.joined(separator: " ") }

    static func verifier(nom: String, titre: String, description: String, octets: [UInt8], separerEntete: Bool = true) throws {
        let url = dossier.appendingPathComponent("\(nom).hex")
        if regenerer {
            try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
            try formater(titre: titre, description: description, octets: octets, separerEntete: separerEntete)
                .write(to: url, atomically: true, encoding: .utf8)
        }
        let texte = try String(contentsOf: url, encoding: .utf8)
        let attendu = try #require(Hex.decoder(texte), "fichier \(nom).hex illisible")
        #expect(attendu == octets, "\(nom).hex diffère de l'encodage actuel")
    }
}

@Suite("Octets de référence du protocole")
struct OctetsDeReferenceTests {
    @Test("Encodage identique au fichier de référence", arguments: Exemples.cas.map(\.nom))
    func encodage(_ nom: String) throws {
        let cas = try #require(Exemples.cas.first { $0.nom == nom })
        try FichiersDeReference.verifier(nom: nom, titre: nom, description: cas.description, octets: Codec.encoder(cas.trame))
    }

    @Test("Le fichier de référence se décode en l'exemple", arguments: Exemples.cas.map(\.nom))
    func decodage(_ nom: String) throws {
        let cas = try #require(Exemples.cas.first { $0.nom == nom })
        let url = FichiersDeReference.dossier.appendingPathComponent("\(nom).hex")
        let octets = try #require(Hex.decoder(try String(contentsOf: url, encoding: .utf8)))
        #expect(try Codec.decoder(octets) == cas.trame)
    }
}

@Suite("Octets et hexadécimal")
struct OctetsTests {
    @Test func entiersEtFlottants() throws {
        var e = EcrivainOctets()
        e.u8(0xAB); e.u16(0xBEEF); e.u32(0xDEAD_BEEF); e.u64(0x0123_4567_89AB_CDEF); e.f32(-1.5); e.booleen(true)
        #expect(e.octets.count == 1 + 2 + 4 + 8 + 4 + 1)
        var l = LecteurOctets(e.octets)
        #expect(try l.u8() == 0xAB)
        #expect(try l.u16() == 0xBEEF)
        #expect(try l.u32() == 0xDEAD_BEEF)
        #expect(try l.u64() == 0x0123_4567_89AB_CDEF)
        #expect(try l.f32() == -1.5)
        #expect(try l.booleen())
        #expect(l.estFini)
        #expect(throws: ErreurDecodage.tronque(attendu: 1, restant: 0)) { try l.u8() }
    }

    @Test func texteUTF8() throws {
        var e = EcrivainOctets()
        e.texteCourt("Café ☕️")
        e.texteLong("")
        var l = LecteurOctets(e.octets)
        #expect(try l.texteCourt() == "Café ☕️")
        #expect(try l.texteLong() == "")
        #expect(EcrivainOctets.tronquerUTF8("aé", maximum: 2) == [0x61])
        var invalide = LecteurOctets([2, 0xC3, 0x28])
        #expect(throws: ErreurDecodage.texteInvalide) { try invalide.texteCourt() }
    }

    @Test func hex() {
        #expect(Hex.encoder([0x00, 0x0F, 0xA5, 0xFF]) == "000fa5ff")
        #expect(Hex.decoder("00 0F # commentaire ignoré zz\n a5ff") == [0x00, 0x0F, 0xA5, 0xFF])
        #expect(Hex.decoder("abc") == nil)
        #expect(Hex.decoder("zz") == nil)
    }
}
