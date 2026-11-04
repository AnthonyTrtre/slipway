import Testing
import SlipwayCoeur
import SlipwaySecurite
@testable import SlipwayMoteur

@Suite("Moteur : appairage et connexion")
struct AppairageTests {
    @Test func premierAppairageDemandeLaConfirmationDesDeuxCotes() {
        var banc = Banc(appairesDAvance: false)
        let (idA, idB) = banc.connecter()
        let ia = banc.a.moteur.instantane(), ib = banc.b.moteur.instantane()
        #expect(ia.pairs.isEmpty && ib.pairs.isEmpty)
        #expect(ia.appairages.count == 1 && ib.appairages.count == 1)
        #expect(ia.appairages[0].code == ib.appairages[0].code)
        #expect(ia.appairages[0].nom == "B" && ib.appairages[0].nom == "A")

        banc.a.moteur.confirmerAppairage(idA, accepte: true)
        banc.reseau.pomper()
        #expect(banc.a.moteur.instantane().pairs.isEmpty)   // l'autre côté n'a pas encore confirmé
        #expect(banc.a.moteur.instantane().appairages.first?.confirmeIci == true)

        banc.b.moteur.confirmerAppairage(idB, accepte: true)
        banc.reseau.pomper()
        #expect(banc.a.moteur.instantane().pairs.map(\.nom) == ["B"])
        #expect(banc.b.moteur.instantane().pairs.map(\.nom) == ["A"])
        #expect(banc.a.magasin.estConnu(banc.b.identite.clePublique))
        #expect(banc.b.magasin.estConnu(banc.a.identite.clePublique))
        #expect(banc.a.moteur.instantane().appairages.isEmpty)
    }

    @Test func pairDejaConnuSansCode() {
        var banc = Banc()
        banc.connecter()
        #expect(banc.a.moteur.instantane().pairs.count == 1)
        #expect(banc.b.moteur.instantane().pairs.count == 1)
        #expect(banc.a.moteur.instantane().appairages.isEmpty)
        // Les écrans ont été échangés : A connaît ceux de B, placés à sa droite.
        let place = banc.a.moteur.instantane().disposition.macs[banc.b.id]
        #expect(place?.ecrans.first?.cadre.largeur == 1920)
        #expect(place?.decalage == Point(x: 1512, y: -49))   // centré verticalement
        // Et B voit A à sa gauche : les deux vues concordent.
        let vueB = banc.b.moteur.instantane().disposition
        #expect(vueB.macs[banc.a.id]!.decalage - vueB.macs[banc.b.id]!.decalage == Point(x: -1512, y: 49))
    }

    @Test func dispositionModifieeSurUnMacPropageeALAutre() {
        var banc = Banc()
        banc.connecter()
        var d = banc.a.moteur.instantane().disposition
        d.macs[banc.b.id]?.decalage = Point(x: 0, y: -1080)   // B au-dessus de A
        banc.a.moteur.modifierDisposition(d)
        banc.reseau.pomper()
        let vueB = banc.b.moteur.instantane().disposition
        #expect(vueB.revision == 1)
        #expect(vueB.macs[banc.b.id]!.decalage - vueB.macs[banc.a.id]!.decalage == Point(x: 0, y: -1080))
        // B monte… non : B descend vers A par son bord bas.
        #expect(banc.b.moteur.evenementLocal(.mouvement(position: Point(x: 200, y: 1079), delta: Point(x: 0, y: 3))))
    }

    @Test func refusDAppairage() {
        var banc = Banc(appairesDAvance: false)
        let (_, idB) = banc.connecter()
        banc.b.moteur.confirmerAppairage(idB, accepte: false)
        banc.reseau.pomper()
        #expect(banc.a.moteur.instantane().appairages.isEmpty && banc.b.moteur.instantane().appairages.isEmpty)
        #expect(banc.a.magasin.nombre == 0 && banc.b.magasin.nombre == 0)
        #expect(banc.lienA.ferme.withLock { $0 } && banc.lienB.ferme.withLock { $0 })
    }

    @Test func versionIncompatibleFermeeAvecUnMessageClair() throws {
        let banc = Banc()
        let lien = LienTest(reseau: banc.reseau, description: "vieux client")
        let id = banc.b.moteur.connexionOuverte(lien, role: .serveur)
        var trame = Codec.encoder(.bonjourClient(BonjourClient(capacites: .toutes, cleIdentite: Array(repeating: 1, count: 32), engagement: Array(repeating: 2, count: 32), nom: "Vieux")))
        trame[12] = 2
        banc.b.moteur.enregistrementRecu(trame, connexion: id)
        let reponse = try #require(lien.enregistrements.withLock { $0.last })
        guard case .auRevoir(let raison, _) = try Codec.decoder(reponse).message else { Issue.record("pas d'AuRevoir"); return }
        #expect(raison == .versionIncompatible)
        #expect(lien.ferme.withLock { $0 })
    }

    @Test func enregistrementAltereFermeLaConnexion() {
        var banc = Banc()
        let (_, idB) = banc.connecter()
        banc.b.moteur.enregistrementRecu(Array(repeating: 0x42, count: 40), connexion: idB)
        banc.reseau.pomper()
        #expect(banc.b.moteur.instantane().pairs.isEmpty)
        #expect(banc.a.moteur.instantane().pairs.isEmpty)   // A apprend la fermeture
    }

    @Test func connexionsCroiseesDedoublonnees() {
        let banc = Banc()
        // A → B et B → A en même temps.
        let l1a = LienTest(reseau: banc.reseau, description: "A→B"), l1b = LienTest(reseau: banc.reseau, description: "B←A")
        let l2b = LienTest(reseau: banc.reseau, description: "B→A"), l2a = LienTest(reseau: banc.reseau, description: "A←B")
        let i1b = banc.b.moteur.connexionOuverte(l1b, role: .serveur)
        let i2a = banc.a.moteur.connexionOuverte(l2a, role: .serveur)
        l1a.relier(a: banc.b.moteur, connexion: i1b)
        l2b.relier(a: banc.a.moteur, connexion: i2a)
        let i1a = banc.a.moteur.connexionOuverte(l1a, role: .client)
        let i2b = banc.b.moteur.connexionOuverte(l2b, role: .client)
        l1b.relier(a: banc.a.moteur, connexion: i1a)
        l2a.relier(a: banc.b.moteur, connexion: i2b)
        banc.reseau.pomper()
        #expect(banc.a.moteur.instantane().pairs.count == 1)
        #expect(banc.b.moteur.instantane().pairs.count == 1)
        // La connexion gardée est la même des deux côtés : un seul des deux liens est fermé de chaque côté.
        let fermes = [l1a, l1b, l2a, l2b].filter { $0.ferme.withLock { $0 } }.count
        #expect(fermes == 2)
    }

    /// Un Mac inconnu qui se présente sans que l'appairage soit ouvert ici est refusé, et sa demande signalée.
    @Test func appairageNonSolliciteRefuse() {
        var banc = Banc(appairesDAvance: false)
        banc.b.moteur.ouvrirAppairage(false)
        banc.connecter()
        let ib = banc.b.moteur.instantane()
        #expect(ib.appairages.isEmpty && ib.pairs.isEmpty)
        #expect(ib.demandeRefusee?.contains("A") == true)
        #expect(banc.a.moteur.instantane().appairages.isEmpty)
        #expect(banc.lienA.ferme.withLock { $0 } || banc.lienB.ferme.withLock { $0 })
    }

    /// La fenêtre d'appairage se referme seule après 2 minutes.
    @Test func appairageExpire() {
        var banc = Banc(appairesDAvance: false)
        #expect(banc.b.moteur.instantane().appairageOuvert != nil)
        banc.tic(Moteur.dureeAppairage + 1)
        #expect(banc.b.moteur.instantane().appairageOuvert == nil)
        banc.connecter()
        #expect(banc.b.moteur.instantane().appairages.isEmpty)
    }

    /// Une seconde demande d'appairage pendant qu'une autre attend est refusée.
    @Test func uneSeuleDemandeDAppairageALaFois() {
        var banc = Banc(appairesDAvance: false)
        banc.connecter()
        let intrus = MacSimule(nom: "Intrus", graine: 201, ecrans: [], horloge: banc.horloge)
        intrus.moteur.ouvrirAppairage()
        let (_, _) = ouvrir(banc, de: intrus, vers: banc.b)
        let demandes = banc.b.moteur.instantane().appairages
        #expect(demandes.map(\.nom) == ["A"])
    }

    /// Connexion qui ne finit jamais sa poignée de main : fermée au bout de 10 s ; inondation plafonnée.
    @Test func connexionsNonAuthentifieesExpireesEtPlafonnees() {
        let banc = Banc()
        let liens = (0..<12).map { LienTest(reseau: banc.reseau, description: "muet \($0)") }
        for l in liens { banc.b.moteur.connexionOuverte(l, role: .serveur) }
        #expect(liens.filter { $0.ferme.withLock { $0 } }.count == 4)   // au-delà de 8 en attente
        banc.tic(Moteur.delaiPoigneeDeMain + 1)
        #expect(liens.allSatisfy { $0.ferme.withLock { $0 } })
    }

    /// Ouvre une connexion de `client` vers `serveur` et pompe la poignée de main.
    private func ouvrir(_ banc: Banc, de client: MacSimule, vers serveur: MacSimule) -> (LienTest, LienTest) {
        let sortant = LienTest(reseau: banc.reseau, description: "\(client.id)→"), entrant = LienTest(reseau: banc.reseau, description: "→\(serveur.id)")
        let iServeur = serveur.moteur.connexionOuverte(entrant, role: .serveur)
        sortant.relier(a: serveur.moteur, connexion: iServeur)
        let iClient = client.moteur.connexionOuverte(sortant, role: .client)
        entrant.relier(a: client.moteur, connexion: iClient)
        banc.reseau.pomper()
        return (sortant, entrant)
    }

    /// Le Mac au plus grand identifiant s'est connecté (l'autre ne le voyait pas), puis le plus petit arrive aussi :
    /// un seul lien survit, le même des deux côtés (celui du plus petit), et le pair reste connecté.
    @Test func connexionTardiveDuPlusPetitRemplaceCelleDuPlusGrand() {
        let banc = Banc()
        let (petit, grand) = banc.a.id < banc.b.id ? (banc.a, banc.b) : (banc.b, banc.a)
        let (g1, g2) = ouvrir(banc, de: grand, vers: petit)
        #expect(petit.moteur.instantane().pairs.count == 1)
        let (p1, p2) = ouvrir(banc, de: petit, vers: grand)
        #expect(petit.moteur.instantane().pairs.count == 1 && grand.moteur.instantane().pairs.count == 1)
        #expect(g1.ferme.withLock { $0 } && g2.ferme.withLock { $0 })
        #expect(!p1.ferme.withLock { $0 } && !p2.ferme.withLock { $0 })
        #expect(petit.moteur.liensEtablis()[grand.id] === p1 && grand.moteur.liensEtablis()[petit.id] === p2)
    }

    /// À l'inverse, une connexion tardive du plus grand vers un lien déjà établi par le plus petit est refusée
    /// sans toucher au lien en place.
    @Test func connexionTardiveDuPlusGrandRefusee() {
        let banc = Banc()
        let (petit, grand) = banc.a.id < banc.b.id ? (banc.a, banc.b) : (banc.b, banc.a)
        let (p1, p2) = ouvrir(banc, de: petit, vers: grand)
        let (g1, g2) = ouvrir(banc, de: grand, vers: petit)
        #expect(petit.moteur.instantane().pairs.count == 1 && grand.moteur.instantane().pairs.count == 1)
        #expect(g1.ferme.withLock { $0 } && g2.ferme.withLock { $0 })
        #expect(!p1.ferme.withLock { $0 } && !p2.ferme.withLock { $0 })
    }
}

@Suite("Moteur : pilotage de bout en bout")
struct PilotageTests {
    @Test func passerSurBEtBouger() throws {
        var banc = Banc()
        banc.connecter()
        #expect(banc.passerSurB())
        #expect(banc.a.curseur.appels == ["figer"])
        #expect(banc.a.moteur.instantane().mode == .pilote(banc.b.id))
        #expect(banc.b.moteur.instantane().mode == .piloteePar(banc.a.id))
        #expect(banc.b.injecteur.mouvements == [Point(x: 4, y: 449)])
        for _ in 0..<10 {
            #expect(banc.a.moteur.evenementLocal(.mouvement(position: Point(x: 1511, y: 400), delta: Point(x: 1.5, y: 0.25))))
        }
        banc.reseau.pomper()
        let derniere = try #require(banc.b.injecteur.mouvements.last)
        #expect(abs(derniere.x - 19) < 0.001 && abs(derniere.y - 451.5) < 0.001)
        // Le canal temps réel a bien servi (pas de repli TCP).
        #expect(banc.lienA.canal.withLock { $0 }!.envoyes.withLock { $0 } >= 10)
    }

    @Test func clavierEtClicsChezLePilote() {
        var banc = Banc()
        banc.connecter()
        _ = banc.passerSurB()
        banc.b.injecteur.vider()
        #expect(banc.a.moteur.evenementLocal(.touche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [.majGauche])))
        #expect(banc.a.moteur.evenementLocal(.touche(usage: CodeTouche.a, enfonce: false, repetition: false, modificateurs: [.majGauche])))
        #expect(banc.a.moteur.evenementLocal(.bouton(.gauche, enfonce: true, nbClics: 1, position: .zero)))
        #expect(banc.a.moteur.evenementLocal(.bouton(.gauche, enfonce: false, nbClics: 1, position: .zero)))
        banc.reseau.pomper()
        #expect(banc.b.injecteur.injections == [
            .touche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [.majGauche]),
            .touche(usage: CodeTouche.a, enfonce: false, repetition: false, modificateurs: [.majGauche]),
            .bouton(.gauche, enfonce: true, nbClics: 1, position: Point(x: 4, y: 449)),
            .bouton(.gauche, enfonce: false, nbClics: 1, position: Point(x: 4, y: 449)),
        ])
    }

    @Test func retourEnLocalParLeBord() {
        var banc = Banc()
        banc.connecter()
        _ = banc.passerSurB()
        #expect(banc.a.moteur.evenementLocal(.mouvement(position: .zero, delta: Point(x: -10, y: 0))))
        banc.reseau.pomper()
        #expect(banc.a.moteur.instantane().mode == .local)
        #expect(banc.b.moteur.instantane().mode == .local)
        #expect(banc.a.curseur.appels.last == "liberer 1506.0,400.0")
        // Revenu en local, les événements ne sont plus avalés.
        #expect(!banc.a.moteur.evenementLocal(.touche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [])))
    }

    @Test func liensCoupeEnPleinGlissementLeMacPiloteRelacheTout() {
        var banc = Banc()
        banc.connecter()
        _ = banc.passerSurB()
        _ = banc.a.moteur.evenementLocal(.bouton(.gauche, enfonce: true, nbClics: 1, position: .zero))
        _ = banc.a.moteur.evenementLocal(.touche(usage: CodeTouche.majGauche, enfonce: true, repetition: false, modificateurs: [.majGauche]))
        banc.reseau.pomper()
        banc.b.injecteur.vider()
        // Le câble est arraché : plus rien ne passe. B s'en rend compte seul, sans réseau, et relâche tout.
        banc.lienA.ferme.withLock { $0 = true }
        banc.lienB.ferme.withLock { $0 = true }
        banc.reseau.udpBloque.withLock { $0 = true }
        for _ in 0..<50 { banc.tic(0.05) }
        #expect(banc.b.moteur.instantane().mode == .local)
        #expect(banc.b.injecteur.injections.contains(.bouton(.gauche, enfonce: false, nbClics: 1, position: Point(x: 4, y: 449))))
        #expect(banc.b.injecteur.injections.contains(.touche(usage: CodeTouche.majGauche, enfonce: false, repetition: false, modificateurs: [])))
        #expect(banc.a.moteur.instantane().mode == .local)
        #expect(banc.a.curseur.appels.last?.hasPrefix("liberer") == true)
    }

    @Test func battementsDeCoeurEtLatence() {
        var banc = Banc()
        banc.connecter()
        for _ in 0..<20 { banc.tic(0.05) }
        let pair = banc.a.moteur.instantane().pairs.first
        #expect(pair?.tempsReelUDP == true)
        #expect(pair?.latenceMs != nil)
        #expect(pair?.degrade == false)
        #expect(banc.b.moteur.instantane().pairs.first?.tempsReelUDP == true)   // le serveur a appris l'adresse du client
    }

    @Test func pertesUDPSansDerive() throws {
        var banc = Banc()
        banc.connecter()
        _ = banc.passerSurB()
        banc.reseau.perteUDP.withLock { $0 = 0.2 }
        for i in 0..<300 {
            _ = banc.a.moteur.evenementLocal(.mouvement(position: .zero, delta: Point(x: i % 2 == 0 ? 0.7 : -0.3, y: 0.1)))
        }
        banc.reseau.pomper()
        let recus = banc.b.injecteur.mouvements.count
        #expect(recus > 150 && recus < 300)
        banc.reseau.perteUDP.withLock { $0 = 0 }
        _ = banc.a.moteur.evenementLocal(.mouvement(position: .zero, delta: Point(x: 0.5, y: 0)))
        banc.reseau.pomper()
        let derniere = try #require(banc.b.injecteur.mouvements.last)
        #expect(abs(derniere.x - (4 + 150 * 0.4 + 0.5)) < 0.01)
        #expect(abs(derniere.y - (449 + 300 * 0.1)) < 0.01)
    }

    @Test func udpBloqueRepliSurLeCanalFiable() throws {
        var banc = Banc()
        banc.reseau.udpBloque.withLock { $0 = true }
        banc.connecter()
        // Côté serveur, aucun datagramme reçu : pas de canal temps réel, les mouvements partent par TCP.
        _ = banc.passerSurB()
        _ = banc.b.moteur.evenementLocal(.mouvement(position: Point(x: 10, y: 10), delta: Point(x: 0, y: 0)))
        #expect(banc.b.moteur.instantane().pairs.first?.tempsReelUDP == false)
        // Côté client, le canal UDP existe mais ne passe pas : il faut quand même que le pilotage marche.
        // Le moteur ne peut pas le savoir tout de suite ; on vérifie au moins que B → A marche par TCP.
        banc.reseau.udpBloque.withLock { $0 = false }
        _ = banc.a.moteur.evenementLocal(.mouvement(position: .zero, delta: Point(x: -10, y: 0)))   // retour sur A
        banc.reseau.pomper()
        // B pilote A : B n'a pas de canal UDP, tout passe par TCP.
        _ = banc.b.moteur.evenementLocal(.mouvement(position: Point(x: 1, y: 300), delta: Point(x: -5, y: 0)))
        banc.reseau.pomper()
        #expect(banc.b.moteur.instantane().mode == .pilote(banc.a.id))
        banc.a.injecteur.vider()
        _ = banc.b.moteur.evenementLocal(.mouvement(position: .zero, delta: Point(x: -3, y: 0)))
        banc.reseau.pomper()
        #expect(banc.a.injecteur.mouvements.count == 1)
    }

    @Test func datagrammeAltereIgnore() throws {
        var banc = Banc()
        banc.connecter()
        _ = banc.passerSurB()
        banc.b.injecteur.vider()
        let canal = try #require(banc.lienA.canal.withLock { $0 })
        // Un attaquant sur le réseau rejoue ou fabrique des datagrammes.
        let retour = CanalTest(reseau: banc.reseau, nom: "attaquant")
        var faux = [UInt8](repeating: 0, count: 60)
        faux[0] = 1
        banc.b.moteur.datagrammeRecu(faux, retour: retour)
        _ = banc.a.moteur.evenementLocal(.mouvement(position: .zero, delta: Point(x: 1, y: 0)))
        banc.reseau.pomper()
        #expect(banc.b.injecteur.mouvements.count == 1)
        _ = canal
    }

    @Test func fusionDesMouvementsQuandLeReseauSature() throws {
        var banc = Banc()
        banc.connecter()
        _ = banc.passerSurB()
        let canal = try #require(banc.lienA.canal.withLock { $0 })
        banc.b.injecteur.vider()
        canal.sature.withLock { $0 = true }
        let avant = canal.envoyes.withLock { $0 }
        for _ in 0..<20 { _ = banc.a.moteur.evenementLocal(.mouvement(position: .zero, delta: Point(x: 1, y: 0))) }
        #expect(canal.envoyes.withLock { $0 } == avant)
        canal.sature.withLock { $0 = false }
        banc.horloge.avancer(0.01)
        banc.a.moteur.tic()
        banc.reseau.pomper()
        let recus = banc.b.injecteur.injections.compactMap { if case .mouvement(let p, let d, _) = $0 { (p, d) } else { nil } }
        #expect(recus.count == 1)
        #expect(recus.first?.0 == Point(x: 24, y: 449))
        #expect(recus.first?.1 == Point(x: 20, y: 0))
    }

    @Test func toutRendreLocalDepuisLeMenu() {
        var banc = Banc()
        banc.connecter()
        _ = banc.passerSurB()
        _ = banc.a.moteur.evenementLocal(.touche(usage: CodeTouche.cmdGauche, enfonce: true, repetition: false, modificateurs: [.cmdGauche]))
        banc.reseau.pomper()
        banc.a.moteur.toutRendreLocal()
        banc.reseau.pomper()
        #expect(banc.a.moteur.instantane().mode == .local)
        #expect(banc.b.moteur.instantane().mode == .local)
        #expect(banc.b.injecteur.injections.last == .touche(usage: CodeTouche.cmdGauche, enfonce: false, repetition: false, modificateurs: []))
    }

    @Test func raccourciDeBascule() {
        var banc = Banc()
        banc.connecter()
        let mods: Modificateurs = [.ctrlGauche, .optionGauche, .cmdGauche]
        #expect(banc.a.moteur.evenementLocal(.touche(usage: CodeTouche.chiffre1 + 1, enfonce: true, repetition: false, modificateurs: mods)))
        banc.reseau.pomper()
        #expect(banc.b.moteur.instantane().mode == .piloteePar(banc.a.id))
        #expect(banc.b.injecteur.mouvements.first == Point(x: 960, y: 540))
    }
}

@Suite("Moteur : presse-papiers")
struct PressePapiersMoteurTests {
    @Test func copierIciCollerLaSansEcho() {
        var banc = Banc()
        banc.connecter()
        banc.a.moteur.compteurPressePapiers(banc.a.pressePapiers.compteur) { banc.a.pressePapiers.texte }   // référence
        banc.a.pressePapiers.copier("Bonjour depuis A ✌️")
        banc.a.moteur.compteurPressePapiers(banc.a.pressePapiers.compteur) { banc.a.pressePapiers.texte }
        banc.reseau.pomper()
        #expect(banc.b.pressePapiers.texte == "Bonjour depuis A ✌️")
        // B voit son presse-papiers changer (c'est nous qui l'avons écrit) : il ne doit rien renvoyer.
        let avant = banc.lienB.enregistrements.withLock { $0.count }
        banc.b.moteur.compteurPressePapiers(0) { "" }
        banc.b.moteur.compteurPressePapiers(banc.b.pressePapiers.compteur) { banc.b.pressePapiers.texte }
        banc.reseau.pomper()
        #expect(banc.lienB.enregistrements.withLock { $0.count } == avant)
    }

    @Test func basculeDeclencheUneVerification() {
        var banc = Banc()
        banc.connecter()
        _ = banc.passerSurB()
        #expect(banc.a.pressePapiers.verifications == 1)
        _ = banc.a.moteur.evenementLocal(.mouvement(position: .zero, delta: Point(x: -10, y: 0)))
        banc.reseau.pomper()
        #expect(banc.b.pressePapiers.verifications == 1)   // B vérifie quand on le quitte
    }
}

@Suite("Moteur : disposition et écrans")
struct DispositionMoteurTests {
    @Test func changementDEcransPropage() {
        var banc = Banc()
        banc.connecter()
        let nouveaux = [Ecran(id: 1, cadre: Rect(x: 0, y: 0, largeur: 1512, hauteur: 982), principal: true),
                        Ecran(id: 2, cadre: Rect(x: 1512, y: 0, largeur: 2560, hauteur: 1440))]
        banc.a.moteur.ecransLocauxChanges(nouveaux)
        banc.reseau.pomper()
        #expect(banc.b.moteur.instantane().disposition.macs[banc.a.id]?.ecrans.count == 2)
    }

    @Test func modifierLaDispositionGardeLesEcransLocaux() {
        var banc = Banc()
        banc.connecter()
        var d = banc.a.moteur.instantane().disposition
        d.macs[banc.a.id]?.ecrans = []
        d.macs[banc.b.id]?.decalage = Point(x: 0, y: -1080)   // B au-dessus de A
        banc.a.moteur.modifierDisposition(d)
        let apres = banc.a.moteur.instantane().disposition
        #expect(apres.macs[banc.a.id]?.ecrans.count == 1)
        #expect(apres.macs[banc.b.id]?.decalage == Point(x: 0, y: -1080))
        #expect(!banc.passerSurB())   // plus rien à droite
        #expect(banc.a.moteur.evenementLocal(.mouvement(position: Point(x: 300, y: 0), delta: Point(x: 0, y: -4))))
    }

    @Test func journalLimiteA200() {
        var banc = Banc()
        banc.connecter()
        for _ in 0..<150 {
            _ = banc.passerSurB()
            _ = banc.a.moteur.evenementLocal(.mouvement(position: .zero, delta: Point(x: -10, y: 0)))
            banc.reseau.pomper()
        }
        #expect(banc.a.moteur.instantane().journal.count == 200)
    }
}
