import Foundation
import Synchronization
import Testing
@testable import SlipwayCoeur
@testable import SlipwaySecurite

/// Aléa déterministe : octets graine, graine+1, graine+2… (vecteurs de référence reproductibles).
final class AleaTest: SourceAlea {
    private let etat: Mutex<UInt8>
    init(graine: UInt8) { etat = Mutex(graine) }
    func octets(_ n: Int) -> [UInt8] {
        etat.withLock { e in (0..<n).map { _ in defer { e &+= 1 }; return e } }
    }
}

enum Fixtures {
    static let identiteClient = try! Identite(brut: (0..<32).map { UInt8($0) })
    static let identiteServeur = try! Identite(brut: (0..<32).map { UInt8(0x80 + $0) })

    struct Resultat {
        var client: PoigneeDeMain
        var serveur: PoigneeDeMain
        var trames: [[UInt8]]
        var preuveClient: [UInt8]
        var preuveServeur: [UInt8]
    }

    /// Poignée de main complète entre deux valeurs, avec une altération optionnelle des trames en transit.
    static func poignee(alterer: (Int, inout [UInt8]) -> Void = { _, _ in }) throws -> Resultat {
        var client = PoigneeDeMain(role: .client, identite: identiteClient, nom: "Client", capacites: .toutes, portUDP: 0, alea: AleaTest(graine: 0x10))
        var serveur = PoigneeDeMain(role: .serveur, identite: identiteServeur, nom: "Serveur", capacites: [.pointeur, .clavier], portUDP: 24851, alea: AleaTest(graine: 0x60))
        var trames: [[UInt8]] = []
        var t1 = try client.demarrer().enClair[0]
        alterer(0, &t1); trames.append(t1)
        let s1 = try serveur.recevoirEnClair(t1)
        var t2 = s1.enClair[0]
        alterer(1, &t2); trames.append(t2)
        let s2 = try client.recevoirEnClair(t2)
        var t3 = s2.enClair[0]
        alterer(2, &t3); trames.append(t3)
        let s3 = try serveur.recevoirEnClair(t3)
        guard case .preuve(let pc) = s2.scelles[0], case .preuve(let ps) = s3.scelles[0] else { throw ErreurSecurite.messageInattendu("preuve") }
        return Resultat(client: client, serveur: serveur, trames: trames, preuveClient: pc, preuveServeur: ps)
    }
}

@Suite("Poignée de main et appairage")
struct PoigneeDeMainTests {
    @Test func lesDeuxCotesDeriventLesMemesClesEtLeMemeCode() throws {
        var r = try Fixtures.poignee()
        let c = try #require(r.client.materiel), s = try #require(r.serveur.materiel)
        #expect(c.codeVerification == s.codeVerification)
        #expect(c.codeVerification.count == 6 && c.codeVerification.allSatisfy(\.isNumber))
        #expect(c.cleEnvoiFlux == s.cleReceptionFlux && c.cleReceptionFlux == s.cleEnvoiFlux)
        #expect(c.cleEnvoiDatagrammes == s.cleReceptionDatagrammes && c.cleReceptionDatagrammes == s.cleEnvoiDatagrammes)
        #expect(Set([c.cleEnvoiFlux, c.cleReceptionFlux, c.cleEnvoiDatagrammes, c.cleReceptionDatagrammes]).count == 4)
        #expect(c.idCanalTempsReel == s.idCanalTempsReel && c.idCanalTempsReel.count == 8)
        #expect(c.idPair == Fixtures.identiteServeur.id && s.idPair == Fixtures.identiteClient.id)
        #expect(c.nomPair == "Serveur" && s.nomPair == "Client")
        #expect(c.capacites == [.pointeur, .clavier] && s.capacites == [.pointeur, .clavier])
        #expect(c.portUDPPair == 24851 && s.portUDPPair == nil)
        try r.client.recevoirPreuve(r.preuveServeur)
        try r.serveur.recevoirPreuve(r.preuveClient)
        #expect(r.client.etat == .authentifiee && r.serveur.etat == .authentifiee)
    }

    @Test func preuveInverseeOuAltereeRefusee() throws {
        var r = try Fixtures.poignee()
        // La preuve du client présentée au client (rôle inversé) ne vaut rien.
        #expect(throws: ErreurSecurite.signatureInvalide) { try r.client.recevoirPreuve(r.preuveClient) }
        var r2 = try Fixtures.poignee()
        var alteree = r2.preuveServeur
        alteree[10] ^= 1
        #expect(throws: ErreurSecurite.signatureInvalide) { try r2.client.recevoirPreuve(alteree) }
        #expect(r2.client.etat == .echec(.signatureInvalide))
    }

    @Test func intermediaireQuiChangeUneCleEphemereDonneDesCodesDifferents() throws {
        // Un attaquant remplace la clé éphémère du serveur : les deux Mac affichent des codes différents (et les clés divergent).
        let r = try Fixtures.poignee { i, trame in if i == 1 { trame[8 + 4 + 2 + 4 + 32] ^= 0x55 } }
        let c = try #require(r.client.materiel), s = try #require(r.serveur.materiel)
        #expect(c.codeVerification != s.codeVerification)
        #expect(c.cleEnvoiFlux != s.cleReceptionFlux)
    }

    @Test func revelationQuiNeCorrespondPasALEngagement() {
        #expect(throws: ErreurSecurite.engagementInvalide) {
            _ = try Fixtures.poignee { i, trame in if i == 2 { trame[9] ^= 1 } }
        }
    }

    @Test func versionMajeureIncompatible() throws {
        var serveur = PoigneeDeMain(role: .serveur, identite: Fixtures.identiteServeur, nom: "S")
        var trame = Codec.encoder(.bonjourClient(BonjourClient(capacites: .toutes, cleIdentite: Fixtures.identiteClient.clePublique, engagement: Array(repeating: 0, count: 32), nom: "C")))
        trame[12] = 9
        #expect(throws: ErreurSecurite.versionIncompatible(9)) { _ = try serveur.recevoirEnClair(trame) }
    }

    @Test func messagesHorsSequenceRefuses() throws {
        var client = PoigneeDeMain(role: .client, identite: Fixtures.identiteClient, nom: "C")
        #expect(throws: ErreurSecurite.self) { _ = try client.recevoirEnClair(Codec.encoder(.revelation(Revelation(cleEphemere: Array(repeating: 1, count: 32), alea: Array(repeating: 2, count: 16))))) }
        var serveur = PoigneeDeMain(role: .serveur, identite: Fixtures.identiteServeur, nom: "S")
        #expect(throws: ErreurSecurite.self) { _ = try serveur.demarrer() }
        #expect(throws: ErreurSecurite.self) { try serveur.recevoirPreuve(Array(repeating: 0, count: 64)) }
        #expect(throws: ErreurSecurite.self) { _ = try serveur.recevoirEnClair([1, 2, 3]) }
    }

    @Test func codeSixChiffres() {
        #expect(Derivation.codeSixChiffres([0, 0, 0, 7]) == "000007")
        #expect(Derivation.codeSixChiffres([0xFF, 0xFF, 0xFF, 0xFF]) == "967295")
        #expect(Derivation.codeSixChiffres([0x00, 0x0F, 0x42, 0x40]) == "000000")   // 1 000 000
    }

    @Test func identite() throws {
        let i = Identite()
        let copie = try Identite(brut: i.brut)
        #expect(copie.clePublique == i.clePublique)
        #expect(i.id.rawValue.count == 16)
        let sig = try i.signer([1, 2, 3])
        #expect(Identite.verifier(signature: sig, message: [1, 2, 3], clePublique: i.clePublique))
        #expect(!Identite.verifier(signature: sig, message: [1, 2, 4], clePublique: i.clePublique))
        #expect(!Identite.verifier(signature: sig, message: [1, 2, 3], clePublique: [1]))
        #expect(throws: ErreurSecurite.cleInvalide) { _ = try Identite(brut: [1, 2, 3]) }
    }
}

@Suite("Canaux scellés")
struct ScelleursTests {
    func materiels() throws -> (MaterielSession, MaterielSession) {
        let r = try Fixtures.poignee()
        return (try #require(r.client.materiel), try #require(r.serveur.materiel))
    }

    @Test func fluxAllerRetourDansLOrdre() throws {
        let (c, s) = try materiels()
        var envoi = ScelleurFlux(materiel: c), reception = ScelleurFlux(materiel: s)
        for i in 0..<50 {
            let trame = Codec.encoder(.ping(horodatage: UInt64(i)), sequence: UInt32(i))
            let scelle = envoi.sceller(trame)
            #expect(scelle.count == trame.count + 16)
            #expect(try reception.ouvrir(scelle) == trame)
        }
        // Et dans l'autre sens, avec l'autre clé.
        var retour = ScelleurFlux(materiel: s), recu = ScelleurFlux(materiel: c)
        #expect(try recu.ouvrir(retour.sceller([42])) == [42])
    }

    @Test func fluxRefuseAlterationRejeuEtDesordre() throws {
        let (c, s) = try materiels()
        var envoi = ScelleurFlux(materiel: c)
        let a = envoi.sceller([1, 2, 3]), b = envoi.sceller([4, 5, 6])
        var r1 = ScelleurFlux(materiel: s)
        #expect(throws: ErreurSecurite.dechiffrementImpossible) { _ = try r1.ouvrir(b) }   // désordre
        var r2 = ScelleurFlux(materiel: s)
        var altere = a
        altere[0] ^= 0x80
        #expect(throws: ErreurSecurite.dechiffrementImpossible) { _ = try r2.ouvrir(altere) }
        var r3 = ScelleurFlux(materiel: s)
        _ = try r3.ouvrir(a)
        #expect(throws: ErreurSecurite.dechiffrementImpossible) { _ = try r3.ouvrir(a) }   // rejeu
        var r4 = ScelleurFlux(materiel: c)   // mauvaise clé (sa propre clé d'envoi n'est pas celle de réception)
        #expect(throws: ErreurSecurite.dechiffrementImpossible) { _ = try r4.ouvrir(a) }
        #expect(throws: ErreurSecurite.dechiffrementImpossible) { _ = try r4.ouvrir([1, 2]) }
    }

    @Test func datagrammesPertesDesordreEtRejeu() throws {
        let (c, s) = try materiels()
        var envoi = ScelleurDatagrammes(materiel: c), reception = ScelleurDatagrammes(materiel: s)
        let d = (0..<10).map { envoi.sceller([UInt8($0)]) }
        #expect(d[0].count == ScelleurDatagrammes.tailleEntete + 1 + 16)
        #expect(ScelleurDatagrammes.idCanal(de: d[0]) == c.idCanalTempsReel)
        #expect(try reception.ouvrir(d[0]) == [0])
        #expect(try reception.ouvrir(d[3]) == [3])   // 1 et 2 perdus
        #expect(try reception.ouvrir(d[2]) == [2])   // en retard mais jamais vu : accepté
        #expect(throws: ErreurSecurite.rejeu) { _ = try reception.ouvrir(d[3]) }
        #expect(throws: ErreurSecurite.rejeu) { _ = try reception.ouvrir(d[0]) }
        var altere = d[4]
        altere[12] ^= 1   // compteur modifié : authentifié par les données associées
        #expect(throws: ErreurSecurite.dechiffrementImpossible) { _ = try reception.ouvrir(altere) }
        #expect(try reception.ouvrir(d[4]) == [4])   // l'original passe toujours
        var autreCanal = d[5]
        autreCanal[1] ^= 1
        #expect(throws: ErreurSecurite.datagrammeInvalide) { _ = try reception.ouvrir(autreCanal) }
        #expect(throws: ErreurSecurite.datagrammeInvalide) { _ = try reception.ouvrir([1, 2, 3]) }
        #expect(reception.rejetes == 5)
    }

    @Test func fenetreAntiRejeu() {
        var f = FenetreAntiRejeu()
        #expect(f.estAcceptable(100))
        f.marquer(100)
        #expect(!f.estAcceptable(100))
        #expect(f.estAcceptable(99) && f.estAcceptable(37) && !f.estAcceptable(36))
        f.marquer(99)
        #expect(!f.estAcceptable(99))
        f.marquer(300)   // saut au-delà de la fenêtre
        #expect(!f.estAcceptable(236) && f.estAcceptable(237) && !f.estAcceptable(300) && f.estAcceptable(301))
        var g = FenetreAntiRejeu()
        for c: UInt64 in [5, 3, 4, 1] { #expect(g.estAcceptable(c)); g.marquer(c) }
        for c: UInt64 in [5, 3, 4, 1] { #expect(!g.estAcceptable(c)) }
        #expect(g.estAcceptable(2))
    }
}

/// Vecteurs cryptographiques de référence (docs/octets-de-reference/vecteurs-crypto.txt) : avec les mêmes clés et le
/// même aléa, toute implémentation doit retrouver ces octets. Les signatures Ed25519 en sont exclues (CryptoKit les
/// randomise), seule leur vérification compte.
@Suite("Vecteurs cryptographiques de référence")
struct VecteursCryptoTests {
    static var fichier: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/octets-de-reference/vecteurs-crypto.txt")
    }

    static func calculer() throws -> [(String, String)] {
        let r = try Fixtures.poignee()
        let c = try #require(r.client.materiel)
        let ephClient = AleaTest(graine: 0x10).octets(32), ephServeur = AleaTest(graine: 0x60).octets(32)
        let secret = try Derivation.secretPartage(privee: ephClient, publiquePair: try Derivation.clePubliqueX25519(privee: ephServeur))
        var dg = ScelleurDatagrammes(materiel: c)
        let datagramme = dg.sceller(Codec.encoder(.ping(horodatage: 1_000_000), sequence: 1))
        var flux = ScelleurFlux(materiel: c)
        let enregistrement = flux.sceller(Codec.encoder(.toutRelacher, sequence: 1))
        let h = Hex.encoder
        return [
            ("identite_client_privee", h(Fixtures.identiteClient.brut)),
            ("identite_client_publique", h(Fixtures.identiteClient.clePublique)),
            ("identite_serveur_privee", h(Fixtures.identiteServeur.brut)),
            ("identite_serveur_publique", h(Fixtures.identiteServeur.clePublique)),
            ("ephemere_client_privee", h(ephClient)),
            ("alea_client", h(AleaTest(graine: 0x30).octets(16))),
            ("ephemere_serveur_privee", h(ephServeur)),
            ("alea_serveur", h(AleaTest(graine: 0x80).octets(16))),
            ("trame_bonjour_client", h(r.trames[0])),
            ("trame_bonjour_serveur", h(r.trames[1])),
            ("trame_revelation", h(r.trames[2])),
            ("empreinte_transcription", h(c.empreinteTranscription)),
            ("secret_partage_x25519", h(secret)),
            ("cle_tcp_client_vers_serveur", h(c.cleEnvoiFlux)),
            ("cle_tcp_serveur_vers_client", h(c.cleReceptionFlux)),
            ("cle_udp_client_vers_serveur", h(c.cleEnvoiDatagrammes)),
            ("cle_udp_serveur_vers_client", h(c.cleReceptionDatagrammes)),
            ("id_canal_temps_reel", h(c.idCanalTempsReel)),
            ("code_verification", c.codeVerification),
            ("message_signe_preuve_client", h(PoigneeDeMain.messagePreuve(role: .client, empreinte: c.empreinteTranscription))),
            ("enregistrement_tcp_client_compteur0_tout_relacher_seq1", h(enregistrement)),
            ("datagramme_client_compteur0_ping_1000000_seq1", h(datagramme)),
        ]
    }

    @Test func vecteursIdentiquesAuFichier() throws {
        let valeurs = try Self.calculer()
        if ProcessInfo.processInfo.environment["SLIPWAY_REGENERER"] == "1" {
            var texte = """
            # Slipway, protocole v1 : vecteurs cryptographiques de référence.
            # Aléa déterministe : l'aléa n°k d'une suite de graine g vaut g, g+1, g+2… (modulo 256).
            # Client : graine 0x10 (clé éphémère X25519 sur 32 octets, puis aléa sur 16 octets → graine 0x30).
            # Serveur : graine 0x60 (clé éphémère puis aléa → graine 0x80). Identités Ed25519 fixes ci-dessous.
            # Capacités : client 7, serveur 3 ; noms « Client » et « Serveur » ; port UDP du serveur 24851.
            # Format : nom = valeur (hexadécimal, sauf le code).

            """
            for (k, v) in valeurs { texte += "\(k) = \(v)\n" }
            try texte.write(to: Self.fichier, atomically: true, encoding: .utf8)
        }
        let contenu = try String(contentsOf: Self.fichier, encoding: .utf8)
        var attendu: [String: String] = [:]
        for ligne in contenu.split(separator: "\n") where !ligne.hasPrefix("#") {
            let morceaux = ligne.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if morceaux.count == 2 { attendu[morceaux[0]] = morceaux[1] }
        }
        #expect(attendu.count == valeurs.count)
        for (k, v) in valeurs { #expect(attendu[k] == v, "valeur « \(k) » différente") }
    }
}
