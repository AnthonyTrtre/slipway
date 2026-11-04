import Testing
@testable import SlipwayCoeur

@Suite("Outils")
struct OutilsTests {
    @Test func backoffProgressifEtPlafonne() {
        var b = Backoff()
        #expect((0..<8).map { _ in b.prochainDelai() } == [0.25, 0.5, 1, 2, 4, 5, 5, 5])
        b.reussite()
        #expect(b.prochainDelai() == 0.25)
    }

    @Test func journalCirculaire() {
        var j = JournalCirculaire<Int>(capacite: 3)
        #expect(j.elements.isEmpty)
        for i in 1...2 { j.ajouter(i) }
        #expect(j.elements == [1, 2])
        for i in 3...7 { j.ajouter(i) }
        #expect(j.elements == [5, 6, 7])
        #expect(j.count == 3)
    }

    @Test func statistiquesDeLatence() {
        var s = StatistiquesLatence(fenetre: 100)
        #expect(s.moyenne == nil && s.centile(99) == nil && s.gigue == nil)
        for ms in [2.0, 4.0, 3.0, 5.0] { s.ajouter(allerRetour: ms / 1000) }
        s.ajouter(allerRetour: -1)
        s.ajouter(allerRetour: .nan)
        #expect(s.nombre == 4)
        #expect(abs(s.moyenne! - 0.0035) < 1e-12)
        #expect(s.centile(50) == 0.003)
        #expect(s.centile(99) == 0.005)
        #expect(abs(s.gigue! - (2.0 + 1.0 + 2.0) / 3 / 1000) < 1e-12)
        for _ in 0..<200 { s.ajouter(allerRetour: 0.001) }
        #expect(s.nombre == 100)
        #expect(abs(s.moyenne! - 0.001) < 1e-12)
        #expect(s.total == 204)
    }

    @Test func compteurDePertes() {
        var c = CompteurPertes()
        for n: UInt32 in [1, 2, 3, 6, 7] { c.noter(n) }
        #expect(c.perdus == 2)
        c.noter(5)   // arrivé en retard
        #expect(c.perdus == 1 && c.desordonnes == 1)
        #expect(abs(c.taux - 1.0 / 7.0) < 1e-12)
        var bouclage = CompteurPertes()
        bouclage.noter(UInt32.max)
        bouclage.noter(1)
        #expect(bouclage.perdus == 1)
    }

    @Test func fusionDesMouvements() {
        var f = FusionMouvements()
        #expect(f.prendre() == nil)
        f.ajouter(Mouvement(dx: 1, dy: 2, x: 10, y: 20, boutons: 0))
        f.ajouter(Mouvement(dx: 0.5, dy: -1, x: 11, y: 21, boutons: 1))
        f.ajouter(Mouvement(dx: 0.25, dy: 0, x: 12, y: 22, boutons: 1))
        #expect(f.fusions == 2)
        #expect(f.prendre() == Mouvement(dx: 1.75, dy: 1, x: 12, y: 22, boutons: 1))
        #expect(f.estVide)
    }

    @Test func empreinteFNV() {
        #expect(Empreinte.fnv1a([]) == 0xcbf2_9ce4_8422_2325)
        #expect(Empreinte.fnv1a(Array("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
        #expect(Empreinte.fnv1a(Array("foobar".utf8)) == 0x8594_4171_f739_67e8)
    }
}

@Suite("Presse-papiers")
struct PressePapiersTests {
    @Test func premiereObservationNEnvoiePas() {
        var s = SynchroPressePapiers()
        let resultats = [12, 12, 13, 13].map { s.compteurLocal($0) }
        #expect(resultats == [false, false, true, false])
    }

    @Test func pasDEchoDeCeQueLOnAEcrit() {
        var s = SynchroPressePapiers()
        _ = s.compteurLocal(1)
        let recu = Array("depuis B".utf8)
        let premier = s.texteRecu(empreinte: Empreinte.fnv1a(recu))
        #expect(premier)
        s.ecritParNous(compteur: 2)
        let aRelire = s.compteurLocal(2)
        #expect(!aRelire)
        // Même si on relit ce texte, il n'est pas renvoyé.
        let renvoi = s.preparerEnvoi(texte: "depuis B")
        #expect(renvoi.isEmpty)
        let doublon = s.texteRecu(empreinte: Empreinte.fnv1a(recu))
        #expect(!doublon)   // doublon reçu ignoré
    }

    @Test func envoiDecoupeEtReassemble() {
        var s = SynchroPressePapiers()
        let texte = String(repeating: "Bonjour é ", count: 10_000)   // 110 000 octets → 4 morceaux
        let messages = s.preparerEnvoi(texte: texte)
        #expect(messages.count == 1 + 4)
        let deuxieme = s.preparerEnvoi(texte: texte)
        #expect(deuxieme.isEmpty)   // déjà envoyé
        var a = AssembleurPressePapiers()
        var resultat = AssembleurPressePapiers.Resultat.enCours
        for m in messages {
            #expect(resultat == .enCours)
            resultat = a.recevoir(m)
        }
        #expect(resultat == .termine(texte: texte, empreinte: Empreinte.fnv1a(Array(texte.utf8))))
        // Chaque morceau tient dans une trame.
        for m in messages { #expect(Codec.encoder(m).count <= Protocole.tailleMaxTrame - 16) }
    }

    @Test func videOuTropGrosIgnore() {
        var s = SynchroPressePapiers(tailleMax: 10)
        let tailles = ["", String(repeating: "x", count: 11), "court"].map { s.preparerEnvoi(texte: $0).count }
        #expect(tailles == [0, 0, 2])
    }

    @Test func assembleurRefuseLesIncoherences() {
        var a = AssembleurPressePapiers(tailleMax: 100)
        #expect(a.recevoir(.pressePapiersMorceau(MorceauPressePapiers(idTransfert: 1, decalage: 0, octets: [1]))) == .rejete("morceau orphelin"))
        #expect(a.recevoir(.pressePapiersOffre(OffrePressePapiers(idTransfert: 1, format: .texteUTF8, taille: 1000, empreinte: 0))) == .rejete("trop gros (1000 octets)"))
        _ = a.recevoir(.pressePapiersOffre(OffrePressePapiers(idTransfert: 2, format: .texteUTF8, taille: 2, empreinte: 0)))
        #expect(a.recevoir(.pressePapiersMorceau(MorceauPressePapiers(idTransfert: 2, decalage: 1, octets: [1]))) == .rejete("morceau incohérent"))
        _ = a.recevoir(.pressePapiersOffre(OffrePressePapiers(idTransfert: 3, format: .texteUTF8, taille: 2, empreinte: 0)))
        #expect(a.recevoir(.pressePapiersMorceau(MorceauPressePapiers(idTransfert: 3, decalage: 0, octets: [0x61, 0x62]))) == .rejete("empreinte différente"))
        let invalide: [UInt8] = [0xC3, 0x28]
        _ = a.recevoir(.pressePapiersOffre(OffrePressePapiers(idTransfert: 4, format: .texteUTF8, taille: 2, empreinte: Empreinte.fnv1a(invalide))))
        #expect(a.recevoir(.pressePapiersMorceau(MorceauPressePapiers(idTransfert: 4, decalage: 0, octets: invalide))) == .rejete("UTF-8 invalide"))
    }
}

@Suite("Suivi des injections")
struct SuiviInjectionsTests {
    @Test func relachementDansLOrdre() {
        var s = SuiviInjections()
        s.noter(.touche(usage: CodeTouche.ctrlGauche, enfonce: true, repetition: false, modificateurs: [.ctrlGauche]))
        s.noter(.touche(usage: CodeTouche.x, enfonce: true, repetition: false, modificateurs: [.ctrlGauche]))
        s.noter(.bouton(.milieu, enfonce: true, nbClics: 1, position: .zero))
        s.noter(.mouvement(position: .zero, delta: .zero, boutonsEnfonces: []))
        #expect(!s.estVide)
        let r = s.toutRelacher(position: Point(x: 1, y: 2))
        #expect(r == [
            .bouton(.milieu, enfonce: false, nbClics: 1, position: Point(x: 1, y: 2)),
            .touche(usage: CodeTouche.x, enfonce: false, repetition: false, modificateurs: [.ctrlGauche]),
            .touche(usage: CodeTouche.ctrlGauche, enfonce: false, repetition: false, modificateurs: []),
        ])
        #expect(s.estVide)
        #expect(s.toutRelacher(position: .zero).isEmpty)
    }
}
