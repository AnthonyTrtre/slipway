#if os(macOS)
import CoreGraphics
import Testing
import SlipwayCoeur
@testable import SlipwayMac

/// Ces tests créent des CGEvent sans jamais les poster : aucune autorisation n'est nécessaire (CI comprise).
@Suite("Adaptateurs macOS : conversions CGEvent")
struct ConversionTests {
    @Test func mouvementLuEnDouble() throws {
        let e = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 100.5, y: 200.25), mouseButton: .left))
        e.setDoubleValueField(.mouseEventDeltaX, value: 3)
        e.setDoubleValueField(.mouseEventDeltaY, value: -2)
        guard case .mouvement(let p, let d, let glisse)? = ConversionEvenements.versEvenementLocal(e, type: .mouseMoved), !glisse else { Issue.record("pas un mouvement"); return }
        #expect(p == Point(x: 100.5, y: 200.25))
        #expect(d == Point(x: 3, y: -2))
        // Un CGEvent synthétique ne garde pas forcément la fraction d'un delta : on la lit si macOS la fournit
        // (événements réels), sans en dépendre. Vérification de la fluidité réelle : recette manuelle.
        e.setDoubleValueField(.mouseEventDeltaX, value: 0.375)
        print("Delta 0,375 relu par CGEvent : \(e.getDoubleValueField(.mouseEventDeltaX))")
    }

    @Test func boutonsEtDoubleClic() throws {
        let e = try #require(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: CGPoint(x: 1, y: 2), mouseButton: .right))
        e.setIntegerValueField(.mouseEventClickState, value: 2)
        #expect(ConversionEvenements.versEvenementLocal(e, type: .rightMouseDown) == .bouton(.droit, enfonce: true, nbClics: 2, position: Point(x: 1, y: 2)))
        let autre = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: 4)!))
        guard case .bouton(let b, false, _, _)? = ConversionEvenements.versEvenementLocal(autre, type: .otherMouseUp) else { Issue.record("bouton 5"); return }
        #expect(b.rawValue == 4)
    }

    @Test func touchesEtModificateurs() throws {
        let e = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: true))   // A
        e.flags = CGEventFlags(rawValue: DrapeauxMac.cmd | DrapeauxMac.cmdGauche)
        #expect(ConversionEvenements.versEvenementLocal(e, type: .keyDown) == .touche(usage: CodeTouche.a, enfonce: true, repetition: false, modificateurs: [.cmdGauche]))
        let maj = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0x38, keyDown: true))
        maj.type = .flagsChanged
        maj.flags = CGEventFlags(rawValue: DrapeauxMac.maj | DrapeauxMac.majGauche)
        #expect(ConversionEvenements.versEvenementLocal(maj, type: .flagsChanged) == .touche(usage: CodeTouche.majGauche, enfonce: true, repetition: false, modificateurs: [.majGauche]))
        maj.flags = []
        #expect(ConversionEvenements.versEvenementLocal(maj, type: .flagsChanged) == .touche(usage: CodeTouche.majGauche, enfonce: false, repetition: false, modificateurs: []))
    }

    @Test func defilementContinuAvecPhases() throws {
        let e = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 3, wheel3: 0))
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        guard case .defilement(let d)? = ConversionEvenements.versEvenementLocal(e, type: .scrollWheel) else { Issue.record("pas un défilement"); return }
        #expect(d.continu)
        #expect(d.phase == .changement)
        #expect(d.dyPoints == -12)
    }

    @Test func injectionAllerRetour() throws {
        let cas: [Injection] = [
            .mouvement(position: Point(x: 10.5, y: 20), delta: Point(x: 4, y: -1), boutonsEnfonces: []),
            .bouton(.gauche, enfonce: true, nbClics: 3, position: Point(x: 5, y: 6)),
            .touche(usage: CodeTouche.a, enfonce: false, repetition: false, modificateurs: [.optionDroit]),
        ]
        for i in cas {
            let e = try #require(ConversionEvenements.fabriquer(i, source: nil).first)
            #expect(ConversionEvenements.estInjecteParSlipway(e))
            let local = ConversionEvenements.versEvenementLocal(e, type: e.type)
            switch (i, local) {
            case (.mouvement(let p, let d, let b), .mouvement(let p2, let d2, let glisse)?): #expect(p == p2 && d == d2 && glisse == !b.isEmpty)
            case (.bouton(let b, let enf, let n, let p), .bouton(let b2, let enf2, let n2, let p2)?): #expect(b == b2 && enf == enf2 && n == n2 && p == p2)
            case (.touche(let u, let enf, _, let m), .touche(let u2, let enf2, _, let m2)?): #expect(u == u2 && enf == enf2 && m == m2)
            default: Issue.record("\(i) → \(String(describing: local))")
            }
        }
    }

    @Test func glisserAvecBoutonEnfonce() throws {
        let e = try #require(ConversionEvenements.fabriquer(.mouvement(position: .zero, delta: .zero, boutonsEnfonces: [.gauche]), source: nil).first)
        #expect(e.type == .leftMouseDragged)
        let d = try #require(ConversionEvenements.fabriquer(.mouvement(position: .zero, delta: .zero, boutonsEnfonces: [.droit]), source: nil).first)
        #expect(d.type == .rightMouseDragged)
    }

    @Test func modificateurInjecteCommeFlagsChanged() throws {
        let e = try #require(ConversionEvenements.fabriquer(.touche(usage: CodeTouche.cmdGauche, enfonce: true, repetition: false, modificateurs: [.cmdGauche]), source: nil).first)
        #expect(e.type == .flagsChanged)
        #expect(e.getIntegerValueField(.keyboardEventKeycode) == 0x37)
        #expect(e.flags.contains(.maskCommand))
    }

    @Test func defilementInjecte() throws {
        let d = Defilement(dxPoints: 2, dyPoints: -7, dxLignes: 0, dyLignes: -1, phase: .debut, inertie: .aucune, continu: true)
        let e = try #require(ConversionEvenements.fabriquer(.defilement(d, position: .zero), source: nil).first)
        #expect(e.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(e.getIntegerValueField(.scrollWheelEventScrollPhase) == 1)
        #expect(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) == -7)
    }

    @Test func toucheMediaInjectee() throws {
        let e = try #require(ConversionEvenements.fabriquer(.toucheSysteme(ToucheSysteme(usage: 0xCD, enfonce: true, repetition: false)), source: nil).first)
        #expect(e.type.rawValue == ConversionEvenements.typeSystemDefined)
        #expect(ConversionEvenements.versEvenementLocal(e, type: e.type) == .toucheSysteme(ToucheSysteme(usage: 0xCD, enfonce: true, repetition: false)))
    }

    @Test func masqueContientLesTypesUtiles() {
        let m = ConversionEvenements.masque
        for t: CGEventType in [.mouseMoved, .leftMouseDown, .keyDown, .flagsChanged, .scrollWheel] { #expect(m & (1 << CGEventMask(t.rawValue)) != 0) }
        #expect(m & (1 << 14) != 0)
    }

    @Test func ecransListesEnPoints() {
        for e in EcransMac.lister() {
            #expect(e.cadre.largeur > 0 && e.cadre.hauteur > 0 && e.echelle >= 1)
        }
    }
}
#endif
