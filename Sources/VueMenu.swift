import SwiftUI
import SlipwayCoeur
import SlipwayMoteur
import SlipwayMac
import SocleBarreDeMenus

/// Contenu de la fenêtre de barre de menus.
struct VueMenu: View {
    let controleur: Controleur
    @Environment(\.openWindow) private var ouvrirFenetre
    @State private var adresse = ""
    @State private var ouvertureALaConnexion = OuvertureALaConnexion.active

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            entete
            if let erreur = controleur.erreurDemarrage {
                Label(erreur, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if !controleur.permissionsOK { permissions }
            if let app = controleur.saisieSecurisee {
                Label("Saisie sécurisée active (\(app)) : le clavier ne peut pas partir vers un autre Mac.", systemImage: "lock.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            if let i = controleur.instantane {
                ForEach(i.appairages) { demande in VueDemandeAppairage(demande: demande, controleur: controleur) }
                macsConnectes(i)
            }
            macsDecouverts
            appairage
            Divider()
            Picker("Ce Mac", selection: Binding(get: { controleur.principal }, set: { controleur.choisirPrincipal($0) })) {
                Text("Principal").tag(true)
                Text("Secondaire").tag(false)
            }
            .pickerStyle(.segmented)
            .help("Principal : sa souris et son clavier passent sur les autres Mac. Secondaire : il se laisse seulement piloter.")
            Divider()
            commandes
        }
        .padding(12)
        .frame(width: 340)
    }

    private var entete: some View {
        HStack {
            Text("Slipway").font(.headline)
            Spacer()
            Text(texteMode).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var texteMode: String {
        guard let i = controleur.instantane else { return "arrêté" }
        let nom = { (id: IdPair) in i.disposition.macs[id]?.nom ?? id.rawValue }
        switch i.mode {
        case .local: return "En local"
        case .pilote(let id): return "Pilote \(nom(id))"
        case .piloteePar(let id): return "Piloté par \(nom(id))"
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Autorisations manquantes", systemImage: "hand.raised").font(.callout.bold())
            Text("Slipway a besoin d'« Accessibilité » et de « Surveillance de l'entrée » pour capturer et injecter souris et clavier.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Demander") { controleur.demanderPermissions() }
                Button("Accessibilité…") { Permissions.ouvrirReglagesAccessibilite() }
                Button("Surveillance…") { Permissions.ouvrirReglagesSurveillance() }
            }.controlSize(.small)
        }
    }

    @ViewBuilder
    private func macsConnectes(_ i: Instantane) -> some View {
        if i.pairs.isEmpty {
            Text("Aucun Mac connecté.").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(i.pairs) { p in
                HStack {
                    Image(systemName: p.degrade ? "wifi.exclamationmark" : "desktopcomputer")
                        .foregroundStyle(p.degrade ? .orange : .primary)
                    VStack(alignment: .leading) {
                        Text(p.nom)
                        Text(p.adresse).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let ms = p.latenceMs {
                        Text(String(format: "%.1f ms", ms)).monospacedDigit().font(.callout)
                            .foregroundStyle(ms < 5 ? Color.green : (ms < 15 ? Color.orange : Color.red))
                    }
                    Button { controleur.basculer(vers: p.id) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless).help("Passer sur ce Mac")
                }
            }
        }
    }

    /// Un Mac inconnu n'est accepté que pendant les 2 minutes qui suivent ce bouton (ou « Appairer » ici).
    @ViewBuilder
    private var appairage: some View {
        if let reste = controleur.instantane?.appairageOuvert {
            HStack {
                Label("Appairage ouvert (\(Int(reste.rounded(.up))) s)", systemImage: "link.badge.plus").font(.callout)
                Spacer()
                Button("Fermer") { controleur.ouvrirAppairage(false) }.controlSize(.small)
            }
        } else {
            Button("Appairer un nouveau Mac…") { controleur.ouvrirAppairage(true) }.controlSize(.small)
                .help("Accepte pendant 2 minutes la demande d'un Mac inconnu ; le même code devra s'afficher sur les deux Mac.")
        }
        if let refusee = controleur.instantane?.demandeRefusee {
            Label("Demande ignorée de \(refusee) : ouvrez l'appairage ici puis recommencez depuis l'autre Mac.", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var macsDecouverts: some View {
        let inconnus = controleur.decouverts.filter { !$0.connu }
        if !inconnus.isEmpty {
            Text("Sur le réseau").font(.caption).foregroundStyle(.secondary)
            ForEach(inconnus) { m in
                HStack {
                    Text(m.nom)
                    Spacer()
                    Button("Appairer") { controleur.appairer(m) }.controlSize(.small)
                }
            }
        }
    }

    private var commandes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { controleur.toutRendreLocal() } label: {
                HStack { Text("Tout rendre en local"); Spacer(); Text("⌃⌥⌘L").foregroundStyle(.secondary) }
            }
            Button("Disposition des Mac…") { ouvrir("disposition") }
            Button("Diagnostic…") { ouvrir("diagnostic") }
            HStack {
                TextField("Adresse IP (secours)", text: $adresse).textFieldStyle(.roundedBorder).controlSize(.small)
                Button("Connecter") { controleur.connecter(hote: adresse); adresse = "" }
                    .controlSize(.small).disabled(adresse.isEmpty)
            }
            Toggle("Ouvrir à la connexion", isOn: Binding(get: { ouvertureALaConnexion },
                                                          set: { _ in OuvertureALaConnexion.basculer(); ouvertureALaConnexion = OuvertureALaConnexion.active }))
                .toggleStyle(.checkbox)
            Divider()
            HStack {
                Button("À propos") { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate() }
                Spacer()
                Button("Mises à jour…") { NSApp.activate(); miseAJour.checkForUpdates(nil) }
                Spacer()
                Button("Quitter") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .buttonStyle(.plain)
    }

    private func ouvrir(_ id: String) {
        ouvrirFenetre(id: id)
        NSApp.activate()
    }
}

/// Premier appairage : le même code doit s'afficher sur les deux Mac ; on le confirme des deux côtés.
struct VueDemandeAppairage: View {
    let demande: Instantane.DemandeAppairage
    let controleur: Controleur

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Appairage avec « \(demande.nom) »", systemImage: "link.badge.plus").font(.callout.bold())
            Text(demande.adresse).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text("Vérifiez que ce code s'affiche aussi sur l'autre Mac :").font(.caption)
            Text(codeLisible).font(.system(size: 28, weight: .semibold, design: .monospaced)).frame(maxWidth: .infinity)
            if demande.confirmeIci {
                Text("Confirmé ici. Confirmez aussi sur l'autre Mac.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Les codes sont identiques") { controleur.confirmerAppairage(demande.id, accepte: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Refuser", role: .destructive) { controleur.confirmerAppairage(demande.id, accepte: false) }
                }.controlSize(.small)
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var codeLisible: String {
        let c = demande.code
        return c.count == 6 ? "\(c.prefix(3)) \(c.suffix(3))" : c
    }
}
