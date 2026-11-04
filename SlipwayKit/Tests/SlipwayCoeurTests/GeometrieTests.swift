import Foundation
import Testing
@testable import SlipwayCoeur

/// Dispositions types utilisées par plusieurs suites.
enum Bureaux {
    static let a = IdPair(rawValue: "aaaaaaaaaaaaaaaa")
    static let b = IdPair(rawValue: "bbbbbbbbbbbbbbbb")
    static let c = IdPair(rawValue: "cccccccccccccccc")
    static let d = IdPair(rawValue: "dddddddddddddddd")

    static func ecran(_ id: UInt32, _ x: Double, _ y: Double, _ l: Double, _ h: Double, principal: Bool = true) -> Ecran {
        Ecran(id: id, cadre: Rect(x: x, y: y, largeur: l, hauteur: h), echelle: 2, principal: principal)
    }

    /// A (MacBook 1512×982) à gauche, B (écran 1920×1080) collé à droite, alignés en haut.
    static var deuxMac: Disposition {
        Disposition(macs: [
            a: PlaceMac(nom: "A", ecrans: [ecran(1, 0, 0, 1512, 982)]),
            b: PlaceMac(nom: "B", ecrans: [ecran(1, 0, 0, 1920, 1080)], decalage: Point(x: 1512, y: 0)),
        ])
    }
}

@Suite("Géométrie : rectangles")
struct RectTests {
    @Test func contientEstSemiOuvert() {
        let r = Rect(x: 0, y: 0, largeur: 100, hauteur: 50)
        #expect(r.contient(Point(x: 0, y: 0)))
        #expect(r.contient(Point(x: 99.99, y: 49.99)))
        #expect(!r.contient(Point(x: 100, y: 10)))
        #expect(!r.contient(Point(x: 10, y: 50)))
        #expect(!r.contient(Point(x: -0.01, y: 10)))
    }

    @Test func borner() {
        let r = Rect(x: 10, y: 10, largeur: 100, hauteur: 50)
        #expect(r.borner(Point(x: 50, y: 20)) == Point(x: 50, y: 20))
        #expect(r.borner(Point(x: -5, y: 100)) == Point(x: 10, y: 59.999))
        #expect(r.contient(r.borner(Point(x: 1000, y: 1000))))
    }

    @Test func chevauchementEtUnion() {
        let a = Rect(x: 0, y: 0, largeur: 10, hauteur: 10)
        #expect(!a.chevauche(Rect(x: 10, y: 0, largeur: 5, hauteur: 5)))   // se touchent seulement
        #expect(a.chevauche(Rect(x: 9, y: 9, largeur: 5, hauteur: 5)))
        #expect(a.union(Rect(x: 20, y: -5, largeur: 5, hauteur: 5)) == Rect(x: 0, y: -5, largeur: 25, hauteur: 15))
    }
}

@Suite("Géométrie : passage par les bords")
struct BordsTests {
    let d = Bureaux.deuxMac

    @Test func resteAuMilieu() {
        #expect(d.deplacer(depuis: Point(x: 500, y: 500), de: Point(x: 3.25, y: -1.5), sur: Bureaux.a) == .reste(Point(x: 503.25, y: 498.5)))
    }

    @Test func basculeParLeBordDroitAMemeHauteur() {
        let r = d.deplacer(depuis: Point(x: 1510, y: 400), de: Point(x: 5, y: 0), sur: Bureaux.a)
        guard case .bascule(let vers, let entree, let sortie) = r else { Issue.record("pas de bascule : \(r)"); return }
        #expect(vers == Bureaux.b)
        #expect(entree.y == 400)
        #expect(entree.x >= 0 && entree.x < 5)
        #expect(sortie.x > 1511 && sortie.x < 1512)
    }

    @Test func pousseeLenteContreLeBordFinitParBasculer() {
        // macOS bloque le curseur local à 1511 : de petits déplacements doivent quand même faire basculer.
        let r = d.deplacer(depuis: Point(x: 1511, y: 300), de: Point(x: 0.3, y: 0), sur: Bureaux.a)
        guard case .bascule(let vers, _, _) = r else { Issue.record("pas de bascule : \(r)"); return }
        #expect(vers == Bureaux.b)
    }

    @Test func pasDeBasculeVersLeVide() {
        #expect(d.deplacer(depuis: Point(x: 2, y: 300), de: Point(x: -10, y: 0), sur: Bureaux.a) == .reste(Point(x: 0, y: 300)))
        let r = d.deplacer(depuis: Point(x: 300, y: 980), de: Point(x: 0, y: 10), sur: Bureaux.a)
        guard case .reste(let p) = r else { Issue.record("bascule inattendue"); return }
        #expect(p.y < 982 && p.y > 981)
    }

    @Test func retourEnMiroir() {
        // Depuis B (au bord gauche), revenir sur A à la même hauteur.
        let r = d.deplacer(depuis: Point(x: 1, y: 700), de: Point(x: -4, y: 0), sur: Bureaux.b)
        guard case .bascule(let vers, let entree, _) = r else { Issue.record("pas de bascule"); return }
        #expect(vers == Bureaux.a)
        #expect(entree.y == 700)
        #expect(entree.x > 1505 && entree.x < 1512)
    }

    @Test func bordPartiellementAdjacent() {
        // B est plus haut que A (1080 contre 982) : sous y = 982 côté B, rien à gauche.
        let bas = d.deplacer(depuis: Point(x: 1, y: 1050), de: Point(x: -4, y: 0), sur: Bureaux.b)
        #expect(bas == .reste(Point(x: 0, y: 1050)))
        // B décalé de 500 vers le bas : seule la moitié basse de A le touche.
        var dec = d
        dec.macs[Bureaux.b]!.decalage = Point(x: 1512, y: 500)
        #expect(dec.deplacer(depuis: Point(x: 1511, y: 100), de: Point(x: 3, y: 0), sur: Bureaux.a) == .reste(Point(x: 1511.999, y: 100)))
        guard case .bascule(_, let entree, _) = dec.deplacer(depuis: Point(x: 1511, y: 800), de: Point(x: 3, y: 0), sur: Bureaux.a) else {
            Issue.record("pas de bascule"); return
        }
        #expect(entree.y == 300)
    }

    @Test func coinsMorts() {
        var dc = d
        dc.reglages.tailleCoinsMorts = 20
        #expect(dc.deplacer(depuis: Point(x: 1511, y: 5), de: Point(x: 3, y: 0), sur: Bureaux.a) == .reste(Point(x: 1511.999, y: 5)))
        #expect(dc.deplacer(depuis: Point(x: 1511, y: 970), de: Point(x: 3, y: 0), sur: Bureaux.a) == .reste(Point(x: 1511.999, y: 970)))
        guard case .bascule = dc.deplacer(depuis: Point(x: 1511, y: 30), de: Point(x: 3, y: 0), sur: Bureaux.a) else {
            Issue.record("devrait basculer hors du coin"); return
        }
    }

    @Test func coutureEntreDeuxEcransDuMemeMacNEstPasUneSortie() {
        // A a deux écrans côte à côte ; B est au-dessus du second.
        var dd = Disposition(macs: [
            Bureaux.a: PlaceMac(nom: "A", ecrans: [Bureaux.ecran(1, 0, 0, 1440, 900), Bureaux.ecran(2, 1440, 0, 1920, 1080, principal: false)]),
            Bureaux.b: PlaceMac(nom: "B", ecrans: [Bureaux.ecran(1, 0, 0, 1512, 982)], decalage: Point(x: 1600, y: -982)),
        ])
        #expect(dd.deplacer(depuis: Point(x: 1439.5, y: 300), de: Point(x: 0.4, y: 0), sur: Bureaux.a) == .reste(Point(x: 1439.9, y: 300)))
        guard case .reste(let p) = dd.deplacer(depuis: Point(x: 1439.9, y: 300), de: Point(x: 0.4, y: 0), sur: Bureaux.a) else {
            Issue.record("la couture ne doit pas faire sortir"); return
        }
        #expect(abs(p.x - 1440.3) < 1e-9 && p.y == 300)
        // Monter depuis le second écran mène à B ; depuis le premier, non.
        guard case .bascule(let vers, let entree, _) = dd.deplacer(depuis: Point(x: 2000, y: 0.5), de: Point(x: 0, y: -2), sur: Bureaux.a) else {
            Issue.record("pas de bascule vers le haut"); return
        }
        #expect(vers == Bureaux.b)
        #expect(entree == Point(x: 400, y: 980.5))
        #expect(dd.deplacer(depuis: Point(x: 100, y: 0.5), de: Point(x: 0, y: -2), sur: Bureaux.a) == .reste(Point(x: 100, y: 0)))
        dd.reglages.tailleCoinsMorts = 0
    }

    @Test func trouEntreEcransDeTaillesDifferentesBorne() {
        // Écran 2 plus bas que l'écran 1 : un point sous l'écran 1 est ramené sur le plus proche.
        let place = PlaceMac(nom: "A", ecrans: [Bureaux.ecran(1, 0, 0, 1000, 800), Bureaux.ecran(2, 1000, 0, 1000, 1200)])
        #expect(place.bornerLocal(Point(x: 990, y: 1100)) == Point(x: 1000, y: 1100))
        #expect(place.bornerLocal(Point(x: 500, y: 1100)) == Point(x: 500, y: 799.999))
    }

    @Test func troisEtQuatreMac() {
        // A au centre, B à droite, C à gauche, D au-dessus de A.
        var quatre = Bureaux.deuxMac
        quatre.macs[Bureaux.c] = PlaceMac(nom: "C", ecrans: [Bureaux.ecran(1, 0, 0, 1280, 800)], decalage: Point(x: -1280, y: 100))
        quatre.macs[Bureaux.d] = PlaceMac(nom: "D", ecrans: [Bureaux.ecran(1, 0, 0, 2560, 1440)], decalage: Point(x: -500, y: -1440))
        guard case .bascule(let v1, let e1, _) = quatre.deplacer(depuis: Point(x: 1, y: 500), de: Point(x: -3, y: 0), sur: Bureaux.a) else {
            Issue.record("A → C"); return
        }
        #expect(v1 == Bureaux.c)
        #expect(e1.y == 400)
        guard case .bascule(let v2, let e2, _) = quatre.deplacer(depuis: Point(x: 700, y: 0.5), de: Point(x: 0, y: -3), sur: Bureaux.a) else {
            Issue.record("A → D"); return
        }
        #expect(v2 == Bureaux.d)
        #expect(e2.x == 1200)
        // De D vers B en diagonale (B commence à x = 1512 sous D qui finit à 2060).
        guard case .bascule(let v3, _, _) = quatre.deplacer(depuis: Point(x: 2400, y: 1439.5), de: Point(x: 0, y: 2), sur: Bureaux.d) else {
            Issue.record("D → B"); return
        }
        #expect(v3 == Bureaux.b)
        #expect(quatre.estAccessible(Bureaux.c) && quatre.estAccessible(Bureaux.d))
    }

    @Test func macInconnuOuSansEcran() {
        #expect(d.deplacer(depuis: Point(x: 1, y: 1), de: Point(x: 5, y: 5), sur: Bureaux.c) == .reste(Point(x: 1, y: 1)))
    }

    @Test func versVirtuelEtRetour() {
        let place = d.macs[Bureaux.b]!
        let p = Point(x: 12.5, y: 99)
        #expect(place.versLocal(place.versVirtuel(p)) == p)
    }
}

@Suite("Géométrie : éditeur de disposition")
struct EditionDispositionTests {
    @Test func aimantationAuBord() {
        var d = Bureaux.deuxMac
        d.macs[Bureaux.b]!.decalage = Point(x: 3000, y: 0)
        // Lâché à 25 points du bord droit de A et 15 points sous son haut : il colle et s'aligne.
        let final = d.aimanter(Bureaux.b, decalagePropose: Point(x: 1537, y: 15))
        #expect(final == Point(x: 1512, y: 0))
    }

    @Test func pasDAimantationAuDelaDuSeuil() {
        let d = Bureaux.deuxMac
        #expect(d.aimanter(Bureaux.b, decalagePropose: Point(x: 1700, y: 300), seuil: 40) == Point(x: 1700, y: 300))
    }

    @Test func jamaisDeChevauchement() {
        let d = Bureaux.deuxMac
        var g = GenerateurDeterministe(graine: 7)
        for _ in 0..<500 {
            let p = Point(x: Double(g.next() % 6000) - 3000, y: Double(g.next() % 4000) - 2000)
            let final = d.aimanter(Bureaux.b, decalagePropose: p)
            var e = d
            e.macs[Bureaux.b]!.decalage = final
            let a = e.macs[Bureaux.a]!.englobantVirtuel!, b = e.macs[Bureaux.b]!.englobantVirtuel!
            #expect(!a.chevauche(b), "chevauchement pour \(p) → \(final)")
        }
    }

    @Test func accessibilite() {
        var d = Bureaux.deuxMac
        #expect(d.estAccessible(Bureaux.a) && d.estAccessible(Bureaux.b))
        d.macs[Bureaux.b]!.decalage = Point(x: 1600, y: 0)
        #expect(!d.estAccessible(Bureaux.b))
        d.macs[Bureaux.b]!.decalage = Point(x: 1512, y: 982)   // ne touche que par un coin
        #expect(!d.estAccessible(Bureaux.b))
    }

    @Test func placementAutomatiqueADroitePourUnIdentifiantPlusGrand() {
        var d = Bureaux.deuxMac
        d.macs[Bureaux.c] = PlaceMac(nom: "C", ecrans: [Bureaux.ecran(1, -100, 0, 1000, 500)])
        d.placerAutomatiquement(Bureaux.c)
        let c = d.macs[Bureaux.c]!.englobantVirtuel!
        #expect(c.minX == 1512 + 1920)
        #expect(c.minY == (1080 - 500) / 2)
        #expect(d.estAccessible(Bureaux.c))
    }

    @Test func placementAutomatiqueSymetrique() {
        // Vu de A : B (plus grand) à droite. Vu de B : A (plus petit) à gauche. Même passage dans les deux sens.
        let ecranA = Bureaux.ecran(1, 0, 0, 1512, 982), ecranB = Bureaux.ecran(1, 0, 0, 1920, 1080)
        var vuDeA = Disposition(macs: [Bureaux.a: PlaceMac(nom: "A", ecrans: [ecranA]), Bureaux.b: PlaceMac(nom: "B", ecrans: [ecranB])])
        vuDeA.placerAutomatiquement(Bureaux.b)
        var vuDeB = Disposition(macs: [Bureaux.b: PlaceMac(nom: "B", ecrans: [ecranB]), Bureaux.a: PlaceMac(nom: "A", ecrans: [ecranA])])
        vuDeB.placerAutomatiquement(Bureaux.a)
        let relatifA = vuDeA.macs[Bureaux.b]!.decalage - vuDeA.macs[Bureaux.a]!.decalage
        let relatifB = vuDeB.macs[Bureaux.b]!.decalage - vuDeB.macs[Bureaux.a]!.decalage
        #expect(relatifA == relatifB)
        #expect(relatifA == Point(x: 1512, y: -49))
    }

    @Test func dispositionRecuePlusRecenteSeulement() {
        var d = Bureaux.deuxMac
        let places = [PlaceDecrite(id: Bureaux.b.octets, x: 0, y: -1080)]
        let resultats = [d.appliquer(revision: 0, places: places), d.appliquer(revision: 5, places: places)]
        #expect(resultats == [false, true])
        #expect(d.macs[Bureaux.b]!.decalage == Point(x: 0, y: -1080))
        let ancienne = d.appliquer(revision: 4, places: [PlaceDecrite(id: Bureaux.b.octets, x: 9, y: 9)])
        #expect(!ancienne)
        #expect(d.revision == 5)
        #expect(d.placesDecrites.map(\.id) == [Bureaux.a.octets, Bureaux.b.octets])
    }

    @Test func dispositionSerialisable() throws {
        let d = Bureaux.deuxMac
        let json = try JSONEncoderLeger.encoder(d)
        #expect(try JSONEncoderLeger.decoder(json) == d)
    }
}

enum JSONEncoderLeger {
    static func encoder(_ d: Disposition) throws -> Data { try JSONEncoder().encode(d) }
    static func decoder(_ data: Data) throws -> Disposition { try JSONDecoder().decode(Disposition.self, from: data) }
}

/// Disposition réelle (04/11/2026) : l'Air posé au-dessus de l'écran ultra-large du MacBook Pro.
@Test func passageParLeHautVersUnMacPoseAuDessus() {
    let pro = IdPair(rawValue: "88cd3e90bc05c658"), air = IdPair(rawValue: "157f539fda573367")
    let d = Disposition(macs: [
        pro: PlaceMac(nom: "Pro", ecrans: [
            Ecran(id: 1, cadre: Rect(x: 0, y: 0, largeur: 1728, hauteur: 1117), principal: true),
            Ecran(id: 2, cadre: Rect(x: -3440, y: -200, largeur: 3440, hauteur: 1440), echelle: 1),
            Ecran(id: 3, cadre: Rect(x: -5360, y: -3, largeur: 1920, hauteur: 1080), echelle: 1),
        ]),
        air: PlaceMac(nom: "Air", ecrans: [Ecran(id: 1, cadre: Rect(x: 0, y: 0, largeur: 1470, hauteur: 956), principal: true)],
                      decalage: Point(x: -3108.9317276305687, y: -1156)),
    ], revision: 1)
    guard case .bascule(let vers, let entree, _) = d.deplacer(depuis: Point(x: -2400, y: -200), de: Point(x: 0, y: -3), sur: pro)
    else { Issue.record("pas de bascule"); return }
    #expect(vers == air)
    #expect(entree.y > 950)
}
