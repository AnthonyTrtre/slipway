import Testing
@testable import SlipwayCoeur

/// Un exemplaire de chaque message, avec des valeurs non triviales (réutilisé par les octets de référence).
enum Exemples {
    static let cle = (1...32).map { UInt8($0) }
    static let engagement = (0..<32).map { UInt8(0xA0 &+ $0) }

    static let cas: [(nom: String, trame: Trame, description: String)] = [
        ("bonjour-client", Trame(sequence: 0, message: .bonjourClient(BonjourClient(capacites: .toutes, cleIdentite: cle, engagement: engagement, nom: "Mac d'Anthony é"))),
         "magie SLPW | majeure 1 | mineure 0 | capacités u32 = 7 | clé d'identité (32) | engagement (32) | nom (u8 longueur + UTF-8)"),
        ("bonjour-serveur", Trame(sequence: 0, message: .bonjourServeur(BonjourServeur(capacites: [.pointeur, .clavier], cleIdentite: cle.reversed(), cleEphemere: engagement, alea: Array(cle.prefix(16)), portUDP: 24851, nom: "Bureau"))),
         "magie SLPW | majeure 1 | mineure 0 | capacités u32 = 3 | clé d'identité (32) | clé éphémère (32) | aléa (16) | port UDP u16 = 24851 | nom"),
        ("revelation", Trame(sequence: 0, message: .revelation(Revelation(cleEphemere: engagement, alea: Array(cle.suffix(16))))),
         "clé éphémère X25519 (32) | aléa (16)"),
        ("preuve", Trame(sequence: 1, message: .preuve(signature: (0..<64).map { UInt8($0) })), "signature Ed25519 (64)"),
        ("confirmation-appairage", Trame(sequence: 2, message: .confirmationAppairage), "charge vide"),
        ("au-revoir", Trame(sequence: 3, message: .auRevoir(raison: .versionIncompatible, texte: "Version 2 inconnue")),
         "raison u8 = 1 (version incompatible) | texte (u16 longueur + UTF-8)"),
        ("ecrans", Trame(sequence: 4, message: .ecrans([
            EcranDecrit(id: 1, x: 0, y: 0, largeur: 1512, hauteur: 982, echelle: 2, principal: true),
            EcranDecrit(id: 7, x: -1920, y: -98, largeur: 1920, hauteur: 1080, echelle: 1, principal: false),
        ])), "nombre u8 | pour chaque écran : id u32, x f32, y f32, largeur f32, hauteur f32, échelle f32, principal u8"),
        ("disposition", Trame(sequence: 4, message: .disposition(revision: 3, places: [
            PlaceDecrite(id: [0xAA, 1, 2, 3, 4, 5, 6, 7], x: 0, y: 0),
            PlaceDecrite(id: [0xBB, 1, 2, 3, 4, 5, 6, 7], x: 1512, y: -49),
        ])), "révision u64 | nombre u8 | pour chaque Mac : identifiant (8 octets), décalage x f32, décalage y f32"),
        ("role", Trame(sequence: 4, message: .role(principal: true)), "principal u8 (1 = l'expéditeur devient principal)"),
        ("entree", Trame(sequence: 5, message: .entree(Entree(x: 0.5, y: 431.25, modificateurs: [.majGauche]))),
         "x f32 | y f32 | modificateurs u32 (bit 1 = Maj gauche)"),
        ("sortie", Trame(sequence: 6, message: .sortie(.panique)), "raison u8 = 1 (panique)"),
        ("bouton", Trame(sequence: 7, message: .bouton(EvenementBouton(bouton: .gauche, enfonce: true, nbClics: 2, x: 100.5, y: 200.25))),
         "bouton u8 = 0 (gauche) | enfoncé u8 | nombre de clics u8 = 2 | x f32 | y f32"),
        ("touche", Trame(sequence: 8, message: .touche(EvenementTouche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [.cmdGauche, .majGauche]))),
         "usage HID u16 = 0x0004 (A) | enfoncé u8 | répétition u8 | modificateurs u32 = Cmd gauche + Maj gauche"),
        ("touche-systeme", Trame(sequence: 9, message: .toucheSysteme(ToucheSysteme(usage: 0xE9, enfonce: true, repetition: true))),
         "usage HID consommateur u16 = 0x00E9 (volume +) | enfoncé u8 | répétition u8"),
        ("tout-relacher", Trame(sequence: 10, message: .toutRelacher), "charge vide"),
        ("presse-papiers-offre", Trame(sequence: 11, message: .pressePapiersOffre(OffrePressePapiers(idTransfert: 3, format: .texteUTF8, taille: 6, empreinte: Empreinte.fnv1a(Array("Salut!".utf8))))),
         "id de transfert u32 | format u8 = 1 (texte UTF-8) | taille u32 | empreinte FNV-1a u64"),
        ("presse-papiers-morceau", Trame(sequence: 12, message: .pressePapiersMorceau(MorceauPressePapiers(idTransfert: 3, decalage: 0, octets: Array("Salut!".utf8)))),
         "id de transfert u32 | décalage u32 | octets (reste de la charge)"),
        ("ping", Trame(sequence: 13, message: .ping(horodatage: 1_234_567_890_123)), "horodatage u64 (nanosecondes, horloge de l'émetteur)"),
        ("pong", Trame(sequence: 14, message: .pong(horodatage: 1_234_567_890_123)), "horodatage u64 recopié du ping"),
        ("mouvement", Trame(sequence: 42, message: .mouvement(Mouvement(dx: 1.75, dy: -0.25, x: 812.5, y: 300, boutons: 0b001))),
         "dx f32 | dy f32 | x f32 | y f32 | boutons enfoncés u8 (bit n = bouton n)"),
        ("defilement", Trame(sequence: 43, message: .defilement(Defilement(dxPoints: 0, dyPoints: -12.5, dxLignes: 0, dyLignes: -1, phase: .changement, inertie: .aucune, continu: true))),
         "dx points f32 | dy points f32 | dx lignes f32 | dy lignes f32 | phase u8 | inertie u8 | continu u8"),
    ]
}

@Suite("Protocole binaire")
struct ProtocoleTests {
    @Test("Aller-retour de chaque message", arguments: Exemples.cas.map(\.trame))
    func allerRetour(_ trame: Trame) throws {
        let octets = Codec.encoder(trame)
        #expect(try Codec.decoder(octets) == trame)
        #expect(octets.count == Protocole.tailleEntete + Int(UInt16(octets[2]) | UInt16(octets[3]) << 8))
    }

    @Test func chaqueTypeConnuEstCouvert() {
        let couverts = Set(Exemples.cas.map(\.trame.message.type))
        for t in TypeMessage.allCases { #expect(couverts.contains(t.rawValue), "type \(t) sans exemple") }
    }

    @Test func enteteEnPetitBoutiste() {
        let o = Codec.encoder(Trame(sequence: 0x0102_0304, message: .ping(horodatage: 0x1122_3344_5566_7788)))
        #expect(Array(o.prefix(8)) == [0x30, 0x00, 0x08, 0x00, 0x04, 0x03, 0x02, 0x01])
        #expect(Array(o.suffix(8)) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
    }

    @Test("Toute troncature est refusée proprement", arguments: Exemples.cas.map(\.trame))
    func troncature(_ trame: Trame) {
        let octets = Codec.encoder(trame)
        for n in 0..<octets.count {
            #expect(throws: ErreurDecodage.self) { try Codec.decoder(Array(octets.prefix(n))) }
        }
    }

    @Test func typeInconnuIgnore() throws {
        let octets: [UInt8] = [0x7F, 0, 3, 0, 9, 0, 0, 0, 0xAA, 0xBB, 0xCC]
        let t = try Codec.decoder(octets)
        #expect(t.message == .inconnu(type: 0x7F, charge: [0xAA, 0xBB, 0xCC]))
        #expect(t.sequence == 9)
        #expect(Codec.encoder(t) == octets)
    }

    @Test func champsAjoutesParUneMineureFutureIgnores() throws {
        var octets = Codec.encoder(.ping(horodatage: 5), sequence: 1)
        octets += [1, 2, 3, 4]
        octets[2] = 12
        #expect(try Codec.decoder(octets).message == .ping(horodatage: 5))
    }

    @Test func longueurIncoherente() {
        var octets = Codec.encoder(.ping(horodatage: 5))
        octets.append(0)
        #expect(throws: ErreurDecodage.longueurIncoherente(annoncee: 8, reelle: 9)) { try Codec.decoder(octets) }
    }

    @Test func versionMajeureIncompatible() {
        var octets = Codec.encoder(Exemples.cas[0].trame)
        octets[12] = 2
        #expect(throws: ErreurDecodage.versionIncompatible(majeure: 2)) { try Codec.decoder(octets) }
    }

    @Test func mauvaiseMagie() {
        var octets = Codec.encoder(Exemples.cas[1].trame)
        octets[8] = UInt8(ascii: "X")
        #expect(throws: ErreurDecodage.magiqueInvalide) { try Codec.decoder(octets) }
    }

    @Test func valeursInvalidesRefusees() {
        var bouton = Codec.encoder(.bouton(EvenementBouton(bouton: .droit, enfonce: true, nbClics: 1, x: 0, y: 0)))
        bouton[8] = 40
        #expect(throws: ErreurDecodage.self) { try Codec.decoder(bouton) }
        var booleen = Codec.encoder(.bouton(EvenementBouton(bouton: .droit, enfonce: true, nbClics: 1, x: 0, y: 0)))
        booleen[9] = 2
        #expect(throws: ErreurDecodage.self) { try Codec.decoder(booleen) }
        var nan = Codec.encoder(.mouvement(Mouvement(dx: 0, dy: 0, x: 0, y: 0, boutons: 0)))
        nan.replaceSubrange(8..<12, with: [0x00, 0x00, 0xC0, 0x7F])   // NaN
        #expect(throws: ErreurDecodage.valeurInvalide("flottant non fini")) { try Codec.decoder(nan) }
    }

    @Test func nomTropLongTronqueSansCasserUnCaractere() throws {
        let nom = String(repeating: "é", count: 100)   // 200 octets
        let t = Trame(sequence: 0, message: .bonjourClient(BonjourClient(capacites: [], cleIdentite: Exemples.cle, engagement: Exemples.engagement, nom: nom)))
        guard case .bonjourClient(let b) = try Codec.decoder(Codec.encoder(t)).message else { Issue.record("type"); return }
        #expect(b.nom == String(repeating: "é", count: 32))
    }

    @Test func tropDEcransLimitesA32() throws {
        let ecrans = (0..<40).map { EcranDecrit(id: UInt32($0), x: 0, y: 0, largeur: 10, hauteur: 10, echelle: 1, principal: false) }
        guard case .ecrans(let l) = try Codec.decoder(Codec.encoder(.ecrans(ecrans))).message else { Issue.record("type"); return }
        #expect(l.count == 32)
    }

    @Test func fuzzingLegerNePlantejamais() {
        var g = GenerateurDeterministe(graine: 42)
        for _ in 0..<5_000 {
            var octets = Codec.encoder(Exemples.cas[Int(g.suivant() % UInt64(Exemples.cas.count))].trame)
            for _ in 0..<Int(g.suivant() % 4) where !octets.isEmpty {
                octets[Int(g.suivant() % UInt64(octets.count))] = UInt8(truncatingIfNeeded: g.suivant())
            }
            _ = try? Codec.decoder(octets)
            let aleatoire = (0..<Int(g.suivant() % 64)).map { _ in UInt8(truncatingIfNeeded: g.suivant()) }
            _ = try? Codec.decoder(aleatoire)
        }
    }

    @Test func sequenceAvecBouclage() {
        #expect(Sequence32.plusRecent(2, que: 1))
        #expect(!Sequence32.plusRecent(1, que: 2))
        #expect(!Sequence32.plusRecent(5, que: 5))
        #expect(Sequence32.plusRecent(0, que: UInt32.max))
        #expect(Sequence32.plusRecent(3, que: UInt32.max - 3))
        #expect(!Sequence32.plusRecent(UInt32.max, que: 0))
    }
}

/// Générateur pseudo-aléatoire déterministe (xorshift64*) pour des tests reproductibles.
struct GenerateurDeterministe: RandomNumberGenerator {
    var etat: UInt64
    init(graine: UInt64) { etat = graine == 0 ? 0x9E37_79B9_7F4A_7C15 : graine }
    mutating func next() -> UInt64 {
        etat ^= etat >> 12; etat ^= etat << 25; etat ^= etat >> 27
        return etat &* 0x2545_F491_4F6C_DD1D
    }
    mutating func suivant() -> UInt64 { next() }
}
