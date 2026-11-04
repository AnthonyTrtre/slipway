import Foundation
import Testing
import SlipwayCoeur
@testable import Slipway

/// Tests de la coque d'app. L'essentiel de la logique est testé dans SlipwayKit (`swift test`) ; ici on vérifie
/// que l'app, lancée comme hôte de tests, ne démarre ni capture ni réseau, et que la disposition se sérialise.
@MainActor
@Suite("Coque de l'app")
struct AppTests {
    @Test func sousTestRienNeDemarre() {
        #expect(Controleur.sousTest)
        let c = Controleur()
        #expect(c.instantane == nil)
        #expect(c.erreurDemarrage == nil)
    }

    @Test func dispositionPersistanteEnJSON() throws {
        let id = IdPair(rawValue: "0011223344556677")
        let d = Disposition(macs: [id: PlaceMac(nom: "Test", ecrans: [Ecran(id: 1, cadre: Rect(x: 0, y: 0, largeur: 100, hauteur: 50))])],
                            reglages: ReglagesBords(tailleCoinsMorts: 10, delaiBord: 0.1), revision: 4)
        let data = try JSONEncoder().encode(d)
        #expect(try JSONDecoder().decode(Disposition.self, from: data) == d)
    }

    @Test func observateurRegroupeLesNotifications() async throws {
        let compteur = Compteur()
        let o = ObservateurApp { compteur.n += 1 }
        for _ in 0..<100 { o.moteurAChange() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(compteur.n == 1)
    }
}

@MainActor
final class Compteur { var n = 0 }
