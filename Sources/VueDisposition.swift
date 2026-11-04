import SwiftUI
import SlipwayCoeur

/// Éditeur de disposition : chaque Mac (avec ses écrans) se déplace à la souris, comme dans Réglages > Moniteurs.
/// Au lâcher, il s'aimante aux bords voisins et ne chevauche jamais un autre Mac ; la disposition est envoyée aux pairs.
struct VueDisposition: View {
    let controleur: Controleur
    @State private var glisse: (id: IdPair, decalage: CGSize)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Faites glisser les Mac pour les placer comme sur votre bureau. Le curseur passe d'un Mac à l'autre là où leurs écrans se touchent.")
                .font(.callout).foregroundStyle(.secondary)
            if let d = controleur.instantane?.disposition, !d.macs.isEmpty {
                GeometryReader { geo in plan(d, taille: geo.size) }
                    .frame(minHeight: 280)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                reglages(d)
            } else {
                ContentUnavailableView("Aucun écran connu", systemImage: "display.2")
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 460)
    }

    private func plan(_ d: Disposition, taille: CGSize) -> some View {
        let union = d.macs.values.compactMap(\.englobantVirtuel).reduce(nil as Rect?) { $0?.union($1) ?? $1 }
            ?? Rect(x: 0, y: 0, largeur: 1, hauteur: 1)
        let echelle = min(taille.width / max(union.largeur, 1), taille.height / max(union.hauteur, 1)) * 0.75
        let origine = CGPoint(x: (taille.width - union.largeur * echelle) / 2 - union.minX * echelle,
                              y: (taille.height - union.hauteur * echelle) / 2 - union.minY * echelle)
        let moi = controleur.instantane?.moi
        return ZStack(alignment: .topLeading) {
            ForEach(d.macs.keys.sorted(), id: \.self) { id in
                let place = d.macs[id]!
                let decalage = glisse?.id == id ? glisse!.decalage : .zero
                ForEach(place.ecrans, id: \.id) { ecran in
                    let r = ecran.cadre.decale(de: place.decalage)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(id == moi ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.3))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(id == moi ? Color.accentColor : .secondary, lineWidth: 1.5))
                        .overlay(Text(ecran.principal ? place.nom : "").font(.caption.bold()).padding(4), alignment: .topLeading)
                        .frame(width: r.largeur * echelle, height: r.hauteur * echelle)
                        .offset(x: origine.x + r.minX * echelle + decalage.width, y: origine.y + r.minY * echelle + decalage.height)
                }
                .gesture(DragGesture()
                    .onChanged { g in glisse = (id, g.translation) }
                    .onEnded { g in deposer(id, translation: g.translation, echelle: echelle, dans: d) })
            }
        }
    }

    private func deposer(_ id: IdPair, translation: CGSize, echelle: Double, dans d: Disposition) {
        glisse = nil
        guard let place = d.macs[id] else { return }
        let propose = Point(x: place.decalage.x + translation.width / echelle, y: place.decalage.y + translation.height / echelle)
        var nouvelle = d
        // Aimantation à 12 pixels à l’écran, convertis en points du bureau virtuel.
        nouvelle.macs[id]?.decalage = d.aimanter(id, decalagePropose: propose, seuil: 12 / max(echelle, 0.001))
        controleur.modifierDisposition(nouvelle)
    }

    private func reglages(_ d: Disposition) -> some View {
        Form {
            Section("Passage par les bords") {
                Slider(value: liaison(d, \.reglages.tailleCoinsMorts), in: 0...100, step: 5) {
                    Text("Coins morts : \(Int(d.reglages.tailleCoinsMorts)) pt")
                }
                Slider(value: liaison(d, \.reglages.delaiBord), in: 0...0.5, step: 0.05) {
                    Text("Pousser contre le bord : \(Int(d.reglages.delaiBord * 1000)) ms")
                }
            }
            Section("Vitesse du curseur sur chaque Mac") {
                ForEach(d.macs.keys.sorted().filter { $0 != controleur.instantane?.moi }, id: \.self) { id in
                    Slider(value: liaison(d, \.macs[id]!.facteurVitesse), in: 0.5...2, step: 0.1) {
                        Text("\(d.macs[id]?.nom ?? id.rawValue) : ×\(String(format: "%.1f", d.macs[id]?.facteurVitesse ?? 1))")
                    }
                }
            }
            Section("Mac appairés") {
                ForEach(controleur.macsAppaires, id: \.id) { mac in
                    HStack {
                        Text(mac.nom)
                        Spacer()
                        Button("Oublier", role: .destructive) { controleur.oublier(mac.id) }.controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 200)
    }

    private func liaison(_ d: Disposition, _ chemin: WritableKeyPath<Disposition, Double>) -> Binding<Double> {
        Binding(get: { d[keyPath: chemin] }, set: { v in
            var n = d
            n[keyPath: chemin] = v
            controleur.modifierDisposition(n)
        })
    }
}
