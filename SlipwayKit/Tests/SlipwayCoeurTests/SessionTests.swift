import Testing
@testable import SlipwayCoeur

/// Outils communs aux tests de session.
extension Session {
    static func deTest(moi: IdPair = Bureaux.a, connectes: [IdPair] = [Bureaux.b], disposition: Disposition = Bureaux.deuxMac) -> Session {
        var s = Session(moi: moi, disposition: disposition)
        for p in connectes { _ = s.connecte(p, t: 0) }
        return s
    }

    /// Pousse le curseur local d'A au-delà du bord droit : A pilote B.
    mutating func passerSurB(t: Double = 1, glisse: Bool = false) -> Decision {
        traiter(.mouvement(position: Point(x: 1511, y: 400), delta: Point(x: 5, y: 0), glisse: glisse), t: t)
    }
}

extension Array where Element == Action {
    var envois: [(Message, IdPair)] {
        compactMap { if case .envoyer(let m, let p) = $0 { (m, p) } else if case .envoyerTempsReel(let m, let p) = $0 { (m, p) } else { nil } }
    }
    var injections: [Injection] { compactMap { if case .injecter(let i) = $0 { i } else { nil } } }
    func contient(_ a: Action) -> Bool { contains(a) }
}

let cmdGauche: Modificateurs = [.cmdGauche]

@Suite("Session : pilotage d'un autre Mac")
struct SessionPilotageTests {
    @Test func etatInitialLocal() {
        let s = Session.deTest()
        #expect(s.mode == .local)
        #expect(s.connectes == [Bureaux.b])
    }

    @Test func unMacSecondaireNePassePasSesBords() {
        var s = Session.deTest()
        s.principal = false
        let d = s.passerSurB()
        #expect(!d.avaler)
        #expect(s.mode == .local)
        #expect(s.basculerVers(Bureaux.b).isEmpty)
    }

    @Test func franchirLeBordEnvoieEntreeEtFigeLeCurseur() {
        var s = Session.deTest()
        let d = s.passerSurB()
        #expect(d.avaler)
        #expect(s.mode == .pilote(Bureaux.b))
        #expect(d.actions.contient(.figerCurseurLocal))
        guard case .entree(let e)? = d.actions.envois.first?.0 else { Issue.record("pas d'Entree"); return }
        #expect(e.y == 400)
        #expect(d.actions.contient(.verifierPressePapiers))
    }

    @Test func pasDeBasculeVersUnMacDeconnecte() {
        var s = Session.deTest(connectes: [])
        let d = s.passerSurB()
        #expect(!d.avaler)
        #expect(s.mode == .local)
    }

    @Test func mouvementsEnPilotageEnPositionAbsolueEtPrecisionComplete() {
        var s = Session.deTest()
        _ = s.passerSurB()
        let d = s.traiter(.mouvement(position: Point(x: 1511, y: 400), delta: Point(x: 0.375, y: -0.125)), t: 1.01)
        #expect(d.avaler)
        guard case .envoyerTempsReel(.mouvement(let m), Bureaux.b)? = d.actions.first else { Issue.record("\(d.actions)"); return }
        #expect(m.dx == 0.375 && m.dy == -0.125)
        #expect(Double(m.y) == 399.875)
        #expect(s.positionDistante.x > 0 && s.positionDistante.x < 6)
    }

    @Test func facteurDeVitesseParMac() {
        var dispo = Bureaux.deuxMac
        dispo.macs[Bureaux.b]!.facteurVitesse = 2
        var s = Session.deTest(disposition: dispo)
        _ = s.passerSurB()
        let x0 = s.positionDistante.x
        _ = s.traiter(.mouvement(position: .zero, delta: Point(x: 10, y: 0)), t: 1.1)
        #expect(s.positionDistante.x == x0 + 20)
    }

    @Test func retourParLeBordGaucheAuPointMiroir() {
        var s = Session.deTest()
        _ = s.passerSurB()
        _ = s.traiter(.mouvement(position: .zero, delta: Point(x: 0, y: 300)), t: 1.1)
        let d = s.traiter(.mouvement(position: .zero, delta: Point(x: -50, y: 0)), t: 1.2)
        #expect(s.mode == .local)
        #expect(d.actions.envois.first?.0 == .sortie(.bascule))
        guard case .libererCurseurLocal(let p)? = d.actions.first(where: { if case .libererCurseurLocal = $0 { true } else { false } }) else {
            Issue.record("curseur non libéré"); return
        }
        #expect(p.y == 700)
        #expect(p.x == 1512 + 4 - 50)   // entrée chez B à x = 4 ; mouvement continu : le dépassement se retrouve de l'autre côté
    }

    @Test func boutonsEtDefilementPartentChezLePair() {
        var s = Session.deTest()
        _ = s.passerSurB()
        let clic = s.traiter(.bouton(.gauche, enfonce: true, nbClics: 2, position: .zero), t: 1.1)
        guard case .bouton(let b)? = clic.actions.envois.first?.0 else { Issue.record("pas de clic"); return }
        #expect(b.nbClics == 2 && b.enfonce && Double(b.y) == 400)
        let glisser = s.traiter(.mouvement(position: .zero, delta: Point(x: 10, y: 0), glisse: true), t: 1.2)
        guard case .mouvement(let m)? = glisser.actions.envois.first?.0 else { Issue.record("pas de mouvement"); return }
        #expect(m.boutons == 1)
        let def = Defilement(dxPoints: 0, dyPoints: 3, dxLignes: 0, dyLignes: 0, phase: .changement, inertie: .aucune, continu: true)
        #expect(s.traiter(.defilement(def), t: 1.3).actions == [.envoyerTempsReel(.defilement(def), a: Bureaux.b)])
    }

    @Test func pasDeBasculeBoutonEnfonce() {
        var s = Session.deTest()
        _ = s.traiter(.bouton(.gauche, enfonce: true, nbClics: 1, position: Point(x: 1511, y: 400)), t: 0.5)
        #expect(!s.passerSurB(glisse: true).avaler)
        #expect(s.mode == .local)
        _ = s.traiter(.bouton(.gauche, enfonce: false, nbClics: 1, position: Point(x: 1511, y: 400)), t: 0.6)
        #expect(s.passerSurB().avaler)
    }

    /// Relâchement jamais vu (macOS coupe la capture un instant, verrouillage) : un simple mouvement prouve qu'aucun
    /// bouton n'est enfoncé, les bords ne restent pas bloqués.
    @Test func boutonDontLeRelachementAEteManqueNeBloquePasLesBords() {
        var s = Session.deTest()
        _ = s.traiter(.bouton(.gauche, enfonce: true, nbClics: 1, position: Point(x: 1511, y: 400)), t: 0.5)
        let d = s.passerSurB()
        #expect(d.avaler)
        #expect(s.mode == .pilote(Bureaux.b))
    }

    @Test func toucheDontLeRelachementAEteManqueOublieeApresTroisSecondes() {
        var s = Session.deTest()
        _ = s.traiter(.touche(usage: CodeTouche.tab, enfonce: true, repetition: false, modificateurs: []), t: 0.5)
        #expect(!s.passerSurB(t: 2).avaler)
        #expect(s.passerSurB(t: 3.6).avaler)
        #expect(s.mode == .pilote(Bureaux.b))
    }

    @Test func toucheTenueQuiSeRepeteBloqueToujoursLesBords() {
        var s = Session.deTest()
        _ = s.traiter(.touche(usage: CodeTouche.tab, enfonce: true, repetition: false, modificateurs: []), t: 0.5)
        _ = s.traiter(.touche(usage: CodeTouche.tab, enfonce: true, repetition: true, modificateurs: []), t: 3.4)
        #expect(!s.passerSurB(t: 3.6).avaler)
    }

    @Test func boutonManqueEnPilotageRelacheChezLePair() {
        var s = Session.deTest()
        _ = s.passerSurB()
        _ = s.traiter(.bouton(.gauche, enfonce: true, nbClics: 1, position: .zero), t: 1.1)
        let d = s.traiter(.mouvement(position: .zero, delta: Point(x: 1, y: 0)), t: 1.2)
        let relache = d.actions.envois.contains { if case .bouton(let b) = $0.0 { !b.enfonce } else { false } }
        #expect(relache)
    }

    @Test func pasDeBasculeToucheOrdinaireEnfonceeMaisOuiAvecModificateur() {
        var s = Session.deTest()
        _ = s.traiter(.touche(usage: CodeTouche.tab, enfonce: true, repetition: false, modificateurs: cmdGauche), t: 0.5)
        #expect(!s.passerSurB().avaler)
        _ = s.traiter(.touche(usage: CodeTouche.tab, enfonce: false, repetition: false, modificateurs: cmdGauche), t: 0.6)
        _ = s.traiter(.touche(usage: CodeTouche.cmdGauche, enfonce: true, repetition: false, modificateurs: cmdGauche), t: 0.7)
        #expect(s.passerSurB().avaler)
    }

    @Test func toucheEnfonceeIciRelacheeIciMemeApresBascule() {
        var s = Session.deTest()
        _ = s.traiter(.touche(usage: CodeTouche.cmdGauche, enfonce: true, repetition: false, modificateurs: cmdGauche), t: 0.5)
        _ = s.passerSurB()
        // Le relâchement de Cmd arrive alors qu'on pilote B : il doit rester local (A a reçu l'appui).
        let d = s.traiter(.touche(usage: CodeTouche.cmdGauche, enfonce: false, repetition: false, modificateurs: []), t: 1.1)
        #expect(!d.avaler)
        #expect(d.actions.isEmpty)
    }

    @Test func toucheEnfonceeChezBRelacheeChezBApresRetour() {
        var s = Session.deTest()
        _ = s.passerSurB()
        _ = s.traiter(.touche(usage: CodeTouche.majGauche, enfonce: true, repetition: false, modificateurs: [.majGauche]), t: 1.1)
        _ = s.traiter(.mouvement(position: .zero, delta: Point(x: -50, y: 0)), t: 1.2)   // retour en local avec Maj tenue
        #expect(s.mode == .local)
        let d = s.traiter(.touche(usage: CodeTouche.majGauche, enfonce: false, repetition: false, modificateurs: []), t: 1.3)
        #expect(d.avaler)
        #expect(d.actions.envois.first?.1 == Bureaux.b)
        guard case .touche(let t)? = d.actions.envois.first?.0 else { Issue.record("pas de touche"); return }
        #expect(!t.enfonce && t.usage == CodeTouche.majGauche)
    }

    @Test func clavierEnPilotage() {
        var s = Session.deTest()
        _ = s.passerSurB()
        let d = s.traiter(.touche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [.majDroit]), t: 1.1)
        #expect(d.avaler)
        #expect(d.actions == [.envoyer(.touche(EvenementTouche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [.majDroit])), a: Bureaux.b)])
        let media = s.traiter(.toucheSysteme(ToucheSysteme(usage: 0xCD, enfonce: true, repetition: false)), t: 1.2)
        #expect(media.avaler && media.actions.count == 1)
    }

    @Test func delaiContreLeBord() {
        var dispo = Bureaux.deuxMac
        dispo.reglages.delaiBord = 0.1
        var s = Session.deTest(disposition: dispo)
        #expect(!s.passerSurB(t: 1.00).avaler)
        #expect(!s.passerSurB(t: 1.05).avaler)
        #expect(s.passerSurB(t: 1.11).avaler)
        #expect(s.mode == .pilote(Bureaux.b))
    }

    @Test func pertureDuLienPendantLePilotageRendLaMain() {
        var s = Session.deTest()
        _ = s.passerSurB()
        let actions = s.deconnecte(Bureaux.b)
        #expect(s.mode == .local)
        #expect(actions.contains { if case .libererCurseurLocal = $0 { true } else { false } })
    }

    @Test func delaiSansNouvellesRendLaMainEtCoupeLeLien() {
        var s = Session.deTest()
        _ = s.passerSurB()
        #expect(s.tic(t: 0.5).isEmpty)
        let degrade = s.tic(t: 1.0)
        #expect(s.etatsLiens[Bureaux.b] == .degrade)
        #expect(degrade.contains { if case .journal = $0 { true } else { false } })
        _ = s.recevoir(.pong(horodatage: 0), de: Bureaux.b, sequence: 1, t: 1.1)
        #expect(s.etatsLiens[Bureaux.b] == .bon)
        let perdu = s.tic(t: 3.2)
        #expect(s.mode == .local)
        #expect(perdu.contient(.couperLien(Bureaux.b)))
        #expect(s.connectes.isEmpty)
    }

    @Test func paniqueRendToutEnLocal() {
        var s = Session.deTest()
        _ = s.passerSurB()
        let d = s.traiter(.touche(usage: CodeTouche.l, enfonce: true, repetition: false, modificateurs: [.ctrlGauche, .optionGauche, .cmdGauche]), t: 1.1)
        #expect(d.avaler)
        #expect(s.mode == .local)
        #expect(d.actions.envois.map(\.0) == [.toutRelacher, .sortie(.panique)])
        // Le relâchement du L est avalé aussi (il ne doit pas arriver tout seul quelque part).
        #expect(s.traiter(.touche(usage: CodeTouche.l, enfonce: false, repetition: false, modificateurs: [.ctrlGauche, .optionGauche, .cmdGauche]), t: 1.2).avaler)
    }

    @Test func raccourciDeBasculeVersLeNiemeMac() {
        var s = Session.deTest()
        #expect(s.ordreRaccourcis == [Bureaux.a, Bureaux.b])
        let mods: Modificateurs = [.ctrlGauche, .optionGauche, .cmdGauche]
        let d = s.traiter(.touche(usage: CodeTouche.chiffre1 + 1, enfonce: true, repetition: false, modificateurs: mods), t: 1)
        #expect(d.avaler)
        #expect(s.mode == .pilote(Bureaux.b))
        guard case .entree(let e)? = d.actions.envois.first?.0 else { Issue.record("pas d'Entree"); return }
        #expect(e.x == 960 && e.y == 540)   // centre de l'écran principal de B
        _ = s.traiter(.touche(usage: CodeTouche.chiffre1, enfonce: true, repetition: false, modificateurs: mods), t: 2)
        #expect(s.mode == .local)
        #expect(s.traiter(.touche(usage: CodeTouche.chiffre9, enfonce: true, repetition: false, modificateurs: mods), t: 3).actions.isEmpty)
    }

    @Test func copieLocaleDeclencheLaVerificationDuPressePapiers() {
        var s = Session.deTest()
        let d = s.traiter(.touche(usage: CodeTouche.c, enfonce: false, repetition: false, modificateurs: cmdGauche), t: 1)
        #expect(!d.avaler)
        #expect(d.actions == [.verifierPressePapiers])
    }

    @Test func pairQuiRendLaMain() {
        var s = Session.deTest()
        _ = s.passerSurB()
        let actions = s.recevoir(.sortie(.panique), de: Bureaux.b, sequence: 3, t: 1.2)
        #expect(s.mode == .local)
        #expect(actions.contains { if case .libererCurseurLocal = $0 { true } else { false } })
    }

    @Test func passageDeBVersCSansRevenirSurA() {
        var dispo = Bureaux.deuxMac
        dispo.macs[Bureaux.c] = PlaceMac(nom: "C", ecrans: [Bureaux.ecran(1, 0, 0, 1000, 1080)], decalage: Point(x: 1512 + 1920, y: 0))
        var s = Session.deTest(connectes: [Bureaux.b, Bureaux.c], disposition: dispo)
        _ = s.passerSurB()
        let d = s.traiter(.mouvement(position: .zero, delta: Point(x: 1930, y: 0)), t: 1.1)
        #expect(s.mode == .pilote(Bureaux.c))
        #expect(d.actions.envois.map(\.1) == [Bureaux.b, Bureaux.c])
        #expect(d.actions.envois.first?.0 == .sortie(.bascule))
        #expect(!d.actions.contient(.figerCurseurLocal))   // déjà figé
    }
}

@Suite("Session : Mac piloté")
struct SessionPiloteeTests {
    func pilotee() -> Session {
        var s = Session.deTest(moi: Bureaux.b, connectes: [Bureaux.a])
        _ = s.recevoir(.entree(Entree(x: 2, y: 400, modificateurs: [])), de: Bureaux.a, sequence: 1, t: 1)
        return s
    }

    @Test func entreeInjecteUnPremierMouvement() {
        var s = Session.deTest(moi: Bureaux.b, connectes: [Bureaux.a])
        let actions = s.recevoir(.entree(Entree(x: 2, y: 400, modificateurs: [])), de: Bureaux.a, sequence: 1, t: 1)
        #expect(s.mode == .piloteePar(Bureaux.a))
        #expect(actions.injections == [.mouvement(position: Point(x: 2, y: 400), delta: .zero, boutonsEnfonces: [])])
    }

    @Test func mouvementsPerimesIgnores() {
        var s = pilotee()
        #expect(s.recevoir(.mouvement(Mouvement(dx: 1, dy: 0, x: 10, y: 400, boutons: 0)), de: Bureaux.a, sequence: 10, t: 1.1).injections.count == 1)
        #expect(s.recevoir(.mouvement(Mouvement(dx: 1, dy: 0, x: 9, y: 400, boutons: 0)), de: Bureaux.a, sequence: 9, t: 1.1).isEmpty)
        #expect(s.recevoir(.mouvement(Mouvement(dx: 1, dy: 0, x: 9, y: 400, boutons: 0)), de: Bureaux.a, sequence: 10, t: 1.1).isEmpty)
        #expect(s.mouvementsPerimes == 2)
        #expect(s.positionInjectee == Point(x: 10, y: 400))
    }

    @Test func positionBorneeAuxEcransLocaux() {
        var s = pilotee()
        _ = s.recevoir(.mouvement(Mouvement(dx: 1, dy: 0, x: 5000, y: -20, boutons: 0)), de: Bureaux.a, sequence: 2, t: 1.1)
        #expect(s.positionInjectee == Point(x: 1919.999, y: 0))
    }

    @Test func mouvementsIgnoresSiPasPilotePar() {
        var s = Session.deTest(moi: Bureaux.b, connectes: [Bureaux.a])
        #expect(s.recevoir(.mouvement(Mouvement(dx: 1, dy: 0, x: 10, y: 10, boutons: 0)), de: Bureaux.a, sequence: 2, t: 1).isEmpty)
        #expect(s.recevoir(.touche(EvenementTouche(usage: 4, enfonce: true, repetition: false, modificateurs: [])), de: Bureaux.a, sequence: 2, t: 1).isEmpty)
    }

    @Test func glisserApresAppuiDeBouton() {
        var s = pilotee()
        _ = s.recevoir(.bouton(EvenementBouton(bouton: .gauche, enfonce: true, nbClics: 1, x: 50, y: 60)), de: Bureaux.a, sequence: 2, t: 1.1)
        let a = s.recevoir(.mouvement(Mouvement(dx: 1, dy: 0, x: 51, y: 60, boutons: 1)), de: Bureaux.a, sequence: 3, t: 1.1)
        #expect(a.injections == [.mouvement(position: Point(x: 51, y: 60), delta: Point(x: 1, y: 0), boutonsEnfonces: [.gauche])])
    }

    @Test func sortieRelacheToutDansLOrdre() {
        var s = pilotee()
        let mods: Modificateurs = [.cmdGauche, .majGauche]
        _ = s.recevoir(.touche(EvenementTouche(usage: CodeTouche.cmdGauche, enfonce: true, repetition: false, modificateurs: [.cmdGauche])), de: Bureaux.a, sequence: 2, t: 1)
        _ = s.recevoir(.touche(EvenementTouche(usage: CodeTouche.majGauche, enfonce: true, repetition: false, modificateurs: mods)), de: Bureaux.a, sequence: 3, t: 1)
        _ = s.recevoir(.touche(EvenementTouche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: mods)), de: Bureaux.a, sequence: 4, t: 1)
        _ = s.recevoir(.bouton(EvenementBouton(bouton: .droit, enfonce: true, nbClics: 1, x: 5, y: 5)), de: Bureaux.a, sequence: 5, t: 1)
        _ = s.recevoir(.toucheSysteme(ToucheSysteme(usage: 0xE9, enfonce: true, repetition: false)), de: Bureaux.a, sequence: 6, t: 1)
        let actions = s.recevoir(.sortie(.bascule), de: Bureaux.a, sequence: 7, t: 1.2)
        #expect(s.mode == .local)
        #expect(actions.injections == [
            .bouton(.droit, enfonce: false, nbClics: 1, position: Point(x: 5, y: 5)),
            .touche(usage: CodeTouche.a, enfonce: false, repetition: false, modificateurs: mods),
            .touche(usage: CodeTouche.majGauche, enfonce: false, repetition: false, modificateurs: [.cmdGauche]),
            .touche(usage: CodeTouche.cmdGauche, enfonce: false, repetition: false, modificateurs: []),
            .toucheSysteme(ToucheSysteme(usage: 0xE9, enfonce: false, repetition: false)),
        ])
        #expect(s.injections.estVide)
        #expect(actions.contient(.verifierPressePapiers))
    }

    @Test func perteDuLienEnPleinGlissementRelacheLeBouton() {
        var s = pilotee()
        _ = s.recevoir(.bouton(EvenementBouton(bouton: .gauche, enfonce: true, nbClics: 1, x: 50, y: 60)), de: Bureaux.a, sequence: 2, t: 1.1)
        let actions = s.tic(t: 3.5)   // plus de 2 s sans nouvelles
        #expect(s.mode == .local)
        #expect(actions.injections == [.bouton(.gauche, enfonce: false, nbClics: 1, position: Point(x: 50, y: 60))])
        #expect(actions.contient(.couperLien(Bureaux.a)))
    }

    @Test func paniqueLocaleSurLeMacPilote() {
        var s = pilotee()
        _ = s.recevoir(.touche(EvenementTouche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [])), de: Bureaux.a, sequence: 2, t: 1)
        let d = s.traiter(.touche(usage: CodeTouche.l, enfonce: true, repetition: false, modificateurs: [.ctrlGauche, .optionGauche, .cmdGauche]), t: 1.1)
        #expect(d.avaler)
        #expect(s.mode == .local)
        #expect(d.actions.injections.count == 1)
        #expect(d.actions.envois.map(\.0) == [.sortie(.panique)])
    }

    /// Cas réel (04/11/2026) : le Pro restait « piloté par l'Air » et sa propre souris ne passait plus aucun bord.
    @Test func laVraieSourisDuMacPiloteLuiRendLaMain() {
        var s = pilotee()
        let d = s.traiter(.mouvement(position: Point(x: 700, y: 400), delta: Point(x: 3, y: 0)), t: 1.1)
        #expect(!d.avaler)
        #expect(s.mode == .local)
        #expect(d.actions.envois.map(\.0) == [.sortie(.bascule)])
    }

    @Test func leMacPiloteRepriseParSaSourisPasseEnsuiteSonBord() {
        var s = pilotee()
        let d = s.traiter(.mouvement(position: Point(x: 1, y: 400), delta: Point(x: -5, y: 0)), t: 1.1)
        #expect(d.avaler)
        #expect(s.mode == .pilote(Bureaux.a))
        #expect(d.actions.envois.first?.0 == .sortie(.bascule))
    }

    @Test func toutRelacherEtVeille() {
        var s = pilotee()
        _ = s.recevoir(.touche(EvenementTouche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [])), de: Bureaux.a, sequence: 2, t: 1)
        #expect(s.recevoir(.toutRelacher, de: Bureaux.a, sequence: 3, t: 1).injections.count == 1)
        #expect(s.injections.estVide)
        _ = s.recevoir(.touche(EvenementTouche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [])), de: Bureaux.a, sequence: 4, t: 1)
        let veille = s.toutRendreLocal(raison: .veille)
        #expect(veille.injections.count == 1)
        #expect(veille.envois.map(\.0) == [.sortie(.veille)])
    }

    @Test func copieInjecteeDeclencheLaVerification() {
        var s = pilotee()
        let a = s.recevoir(.touche(EvenementTouche(usage: CodeTouche.c, enfonce: false, repetition: false, modificateurs: [.cmdDroit])), de: Bureaux.a, sequence: 2, t: 1)
        #expect(a.contient(.verifierPressePapiers))
    }

    @Test func ecransDuPairMisAJour() {
        var s = Session.deTest()
        _ = s.recevoir(.ecrans([EcranDecrit(id: 9, x: 0, y: 0, largeur: 800, hauteur: 600, echelle: 1, principal: true)]), de: Bureaux.b, sequence: 1, t: 1)
        #expect(s.disposition.macs[Bureaux.b]?.ecrans.map(\.id) == [9])
        #expect(s.disposition.macs[Bureaux.b]?.decalage == Point(x: 1512, y: 0))   // la place est conservée
    }

    @Test func nouveauMacPlaceADroiteQuandSesEcransArrivent() {
        var s = Session(moi: Bureaux.a, disposition: Disposition(macs: [Bureaux.a: Bureaux.deuxMac.macs[Bureaux.a]!]))
        s.mettreAJourEcrans([], de: Bureaux.c, nom: "C")
        s.mettreAJourEcrans([Bureaux.ecran(1, 0, 0, 1000, 800)], de: Bureaux.c, nom: "")
        #expect(s.disposition.macs[Bureaux.c]?.decalage.x == 1512)
        #expect(s.disposition.macs[Bureaux.c]?.nom == "C")
    }
}

@Suite("Session : propriétés")
struct SessionProprietesTests {
    /// Séquences aléatoires d'appuis et relâchements : après une sortie, plus rien n'est enfoncé chez le piloté.
    @Test func apresSortieRienNEstEnfonce() {
        var g = GenerateurDeterministe(graine: 2026)
        for _ in 0..<200 {
            var s = Session.deTest(moi: Bureaux.b, connectes: [Bureaux.a])
            _ = s.recevoir(.entree(Entree(x: 1, y: 1, modificateurs: [])), de: Bureaux.a, sequence: 1, t: 1)
            var enfonces = Set<UInt16>()
            for i in 0..<Int(g.next() % 40) {
                let usage = [CodeTouche.a, CodeTouche.c, CodeTouche.majGauche, CodeTouche.cmdGauche, CodeTouche.optionDroit, CodeTouche.espace][Int(g.next() % 6)]
                let enfonce = g.next() % 2 == 0
                if enfonce { enfonces.insert(usage) } else { enfonces.remove(usage) }
                _ = s.recevoir(.touche(EvenementTouche(usage: usage, enfonce: enfonce, repetition: false, modificateurs: [])), de: Bureaux.a, sequence: UInt32(i + 2), t: 1)
                if g.next() % 5 == 0 {
                    _ = s.recevoir(.bouton(EvenementBouton(bouton: BoutonSouris(rawValue: UInt8(g.next() % 5)), enfonce: g.next() % 2 == 0, nbClics: 1, x: 3, y: 3)), de: Bureaux.a, sequence: 0, t: 1)
                }
            }
            #expect(s.injections.touches == enfonces)
            let fin: [Action] = switch g.next() % 4 {
            case 0: s.recevoir(.sortie(.bascule), de: Bureaux.a, sequence: 999, t: 1.2)
            case 1: s.deconnecte(Bureaux.a)
            case 2: s.tic(t: 10)
            default: s.toutRendreLocal(raison: .veille)
            }
            let relaches = Set(fin.injections.compactMap { if case .touche(let u, false, _, _) = $0 { u } else { nil } })
            #expect(relaches == enfonces)
            #expect(s.injections.estVide)
            #expect(s.mode == .local)
        }
    }

    /// Pertes de datagrammes (1 %, 10 %, rafales) : comme chaque mouvement porte la position absolue, la position finale
    /// côté piloté est exactement celle du dernier mouvement reçu, sans dérive.
    @Test("Pertes simulées sans dérive", arguments: [0.01, 0.10, 0.30])
    func pertesSansDerive(taux: Double) {
        var a = Session.deTest()
        var b = Session.deTest(moi: Bureaux.b, connectes: [Bureaux.a])
        var g = GenerateurDeterministe(graine: UInt64(taux * 1000))
        var t = 1.0
        let entree = a.passerSurB(t: t)
        for case (let m, Bureaux.b) in entree.actions.envois { _ = b.recevoir(m, de: Bureaux.a, sequence: 0, t: t) }
        var sequence: UInt32 = 0
        var dernierEnvoye: Mouvement?
        var dernierRecu: Mouvement?
        var rafale = 0
        for _ in 0..<2000 {
            t += 0.001
            let dx = Double(Int(g.next() % 7) - 3) * 0.37, dy = Double(Int(g.next() % 7) - 3) * 0.29
            let d = a.traiter(.mouvement(position: .zero, delta: Point(x: dx, y: dy)), t: t)
            guard a.mode == .pilote(Bureaux.b) else { break }
            for case (.mouvement(let m), _) in d.actions.envois {
                sequence += 1
                dernierEnvoye = m
                if rafale == 0, Double(g.next() % 10_000) / 10_000 < taux { rafale = Int(g.next() % 5) + 1 }
                if rafale > 0 { rafale -= 1; continue }
                _ = b.recevoir(.mouvement(m), de: Bureaux.a, sequence: sequence, t: t)
                dernierRecu = m
            }
        }
        // Le prochain datagramme reçu recale tout : la position est celle de l'émetteur.
        if let m = dernierEnvoye, m != dernierRecu { _ = b.recevoir(.mouvement(m), de: Bureaux.a, sequence: sequence + 1, t: t) }
        #expect(abs(b.positionInjectee.x - a.positionDistante.x) < 0.001)
        #expect(abs(b.positionInjectee.y - a.positionDistante.y) < 0.001)
    }
}
