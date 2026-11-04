import SwiftUI
import Sparkle
import SlipwayCoeur
import SocleBarreDeMenus

@main
struct SlipwayApp: App {
    @NSApplicationDelegateAdaptor(Delegue.self) private var delegue

    var body: some Scene {
        MenuBarExtra {
            VueMenu(controleur: delegue.controleur)
        } label: {
            EtiquetteBarreDeMenus(controleur: delegue.controleur)
        }
        .menuBarExtraStyle(.window)

        Window("Disposition des Mac", id: "disposition") {
            VueDisposition(controleur: delegue.controleur)
        }
        .windowResizability(.contentMinSize)

        Window("Diagnostic Slipway", id: "diagnostic") {
            VueDiagnostic(controleur: delegue.controleur)
        }
    }
}

/// Mises à jour intégrées (Sparkle) : archives signées EdDSA, vérifiées avant installation.
@MainActor let miseAJour = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

@MainActor
final class Delegue: NSObject, NSApplicationDelegate {
    let controleur = Controleur()

    func applicationDidFinishLaunching(_ notification: Notification) {
        OuvertureALaConnexion.activerAuPremierLancement()
        if NSClassFromString("XCTestCase") == nil { miseAJour.startUpdater() }   // pas de réseau pendant les tests
    }

    func applicationWillTerminate(_ notification: Notification) {
        controleur.arreter()
    }
}

/// Icône de barre de menus : état du lien et latence. Symboles SF génériques (aucune ressource d'une autre app).
struct EtiquetteBarreDeMenus: View {
    let controleur: Controleur

    var body: some View {
        let i = controleur.instantane
        HStack(spacing: 3) {
            Image(systemName: symbole)
            if let ms = i?.pairs.compactMap(\.latenceMs).max() {
                Text(ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)).monospacedDigit()
            }
        }
    }

    private var symbole: String {
        guard let i = controleur.instantane else { return "rectangle.on.rectangle.slash" }
        if controleur.saisieSecurisee != nil { return "lock.rectangle" }
        if !controleur.permissionsOK || !i.appairages.isEmpty { return "exclamationmark.triangle" }
        if i.pairs.contains(where: \.degrade) { return "wifi.exclamationmark" }
        switch i.mode {
        case .pilote: return "arrow.right.square.fill"
        case .piloteePar: return "arrow.left.square"
        case .local: return i.pairs.isEmpty ? "rectangle.on.rectangle" : "rectangle.on.rectangle.angled"
        }
    }
}
