#if os(macOS)
import Foundation
import Testing
import SlipwayCoeur
@testable import SlipwayMac

/// Copie de fichiers par le presse-papiers : lecture sur le disque, transport, puis pose dans un dossier neuf.
@Suite("Adaptateurs macOS : fichiers du presse-papiers")
struct FichiersTests {
    @Test func appEtFichierAllerRetourSurLeDisque() throws {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("slipway-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: source) }
        let app = source.appendingPathComponent("Outil.app/Contents/MacOS")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let binaire = app.appendingPathComponent("Outil")
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: binaire)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaire.path)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("Outil.app/Contents/Actuel").path, withDestinationPath: "MacOS")
        let photo = source.appendingPathComponent("plage.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: photo)

        let lot = try #require(LecteurFichiers.lot([source.appendingPathComponent("Outil.app"), photo]))
        #expect(lot.racines == ["Outil.app", "plage.png"])
        let recu = try LotFichiers.decoder(lot.encoder())

        let reception = fm.temporaryDirectory.appendingPathComponent("slipway-recus-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: reception) }
        let urls = try EcrivainFichiers.poser(recu, dans: reception)
        #expect(urls.map(\.lastPathComponent) == ["Outil.app", "plage.png"])
        let posee = urls[0].appendingPathComponent("Contents/MacOS/Outil").path
        #expect(fm.contents(atPath: posee) == Data([0xCF, 0xFA, 0xED, 0xFE]))
        #expect(fm.isExecutableFile(atPath: posee))
        #expect(try fm.destinationOfSymbolicLink(atPath: urls[0].appendingPathComponent("Contents/Actuel").path) == "MacOS")
        #expect(fm.contents(atPath: urls[1].path) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
#endif
