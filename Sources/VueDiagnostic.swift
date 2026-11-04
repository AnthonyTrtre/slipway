import SwiftUI
import SlipwayCoeur
import SlipwayMoteur

/// Fenêtre de diagnostic : latence (moyenne, 99e centile), gigue, pertes, interface utilisée, état de la capture et
/// journal des 200 derniers événements de session.
struct VueDiagnostic: View {
    let controleur: Controleur

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Capture").bold(); Text(controleur.captureActive ? "active" : "inactive (autorisations ?)") }
                GridRow { Text("Réactivations du tap").bold(); Text("\(controleur.reactivationsTap)") }
                GridRow { Text("Saisie sécurisée").bold(); Text(controleur.saisieSecurisee ?? "non") }
                if let i = controleur.instantane {
                    GridRow { Text("Ce Mac").bold(); Text("\(controleur.nomMac) (\(i.moi.rawValue))").textSelection(.enabled) }
                    GridRow { Text("Mouvements périmés écartés").bold(); Text("\(i.mouvementsPerimes)") }
                    GridRow { Text("Datagrammes rejetés").bold(); Text("\(i.datagrammesRejetes)") }
                }
            }
            if let i = controleur.instantane, !i.pairs.isEmpty {
                Table(i.pairs) {
                    TableColumn("Mac", value: \.nom)
                    TableColumn("Lien") { p in Text(p.adresse) }
                    TableColumn("UDP") { p in Text(p.tempsReelUDP ? "oui" : "repli TCP") }
                    TableColumn("Moy.") { p in Text(ms(p.latenceMs)) }
                    TableColumn("99e c.") { p in Text(ms(p.p99Ms)) }
                    TableColumn("Gigue") { p in Text(ms(p.gigueMs)) }
                    TableColumn("Pertes") { p in Text(String(format: "%.1f %%", p.tauxPertes * 100)) }
                }
                .frame(minHeight: 90, maxHeight: 140)
            }
            if !controleur.erreursReseau.isEmpty {
                ForEach(controleur.erreursReseau, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            HStack {
                Text("Journal").font(.headline)
                Spacer()
                Button("Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((controleur.instantane?.journal ?? []).joined(separator: "\n"), forType: .string)
                }
            }
            List((controleur.instantane?.journal ?? []).reversed(), id: \.self) { ligne in
                Text(ligne).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("Conseil : pour la meilleure fluidité, préférez un câble Ethernet ou un pont Thunderbolt, sinon un Wi-Fi 5 ou 6 GHz. AirDrop et Handoff font sauter la radio Wi-Fi sur un autre canal et créent des pics de latence.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 480)
    }

    private func ms(_ v: Double?) -> String { v.map { String(format: "%.2f ms", $0) } ?? "–" }
}
