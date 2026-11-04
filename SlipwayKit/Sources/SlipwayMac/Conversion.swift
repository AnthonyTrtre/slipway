#if os(macOS)
import AppKit
import CoreGraphics
import SlipwayCoeur

/// Marque posée sur chaque événement injecté par Slipway (champ `eventSourceUserData`), pour que notre propre
/// capture l'ignore. Valeur : « SLPW » en ASCII.
public enum MarqueurInjection {
    public static let valeur: Int64 = 0x534C_5057
}

/// Conversions CGEvent ↔ événements neutres de SlipwayCoeur. Aucune entrée-sortie : testable en créant des
/// CGEvent sans les poster (aucune autorisation requise).
public enum ConversionEvenements {
    /// Type « système » (touches média, luminosité) : NX_SYSDEFINED, absent de l'énumération Swift.
    public static let typeSystemDefined: UInt32 = 14

    /// Types capturés par le tap.
    public static var masque: CGEventMask {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        var m: CGEventMask = 1 << CGEventMask(typeSystemDefined)
        for t in types { m |= 1 << CGEventMask(t.rawValue) }
        return m
    }

    public static func estInjecteParSlipway(_ e: CGEvent) -> Bool {
        e.getIntegerValueField(.eventSourceUserData) == MarqueurInjection.valeur
    }

    /// CGEvent capturé → événement neutre (nil = type non géré, l'événement passe tel quel).
    public static func versEvenementLocal(_ e: CGEvent, type: CGEventType) -> EvenementLocal? {
        let position = Point(x: Double(e.location.x), y: Double(e.location.y))
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Deltas en double : la partie fractionnaire compte (pavé tactile lent), contrairement aux champs entiers.
            let delta = Point(x: e.getDoubleValueField(.mouseEventDeltaX), y: e.getDoubleValueField(.mouseEventDeltaY))
            return .mouvement(position: position, delta: delta)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let numero = UInt8(clamping: max(0, min(31, e.getIntegerValueField(.mouseEventButtonNumber))))
            let enfonce = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            let clics = UInt8(clamping: max(1, e.getIntegerValueField(.mouseEventClickState)))
            return .bouton(BoutonSouris(rawValue: numero), enfonce: enfonce, nbClics: clics, position: position)
        case .scrollWheel:
            return .defilement(Defilement(
                dxPoints: Float(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
                dyPoints: Float(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)),
                dxLignes: Float(e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)),
                dyLignes: Float(e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)),
                phase: PhasesMac.phase(depuisQuartz: e.getIntegerValueField(.scrollWheelEventScrollPhase)),
                inertie: PhasesMac.inertie(depuisQuartz: e.getIntegerValueField(.scrollWheelEventMomentumPhase)),
                continu: e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0))
        case .keyDown, .keyUp:
            let code = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
            guard let usage = TableTouchesMac.usage(pourCodeMac: code) else { return nil }
            return .touche(usage: usage, enfonce: type == .keyDown, repetition: e.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                           modificateurs: DrapeauxMac.versModificateurs(e.flags.rawValue))
        case .flagsChanged:
            let code = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
            guard let usage = TableTouchesMac.usage(pourCodeMac: code),
                  let enfonce = DrapeauxMac.estEnfoncee(codeMac: code, drapeaux: e.flags.rawValue) else { return nil }
            return .touche(usage: usage, enfonce: enfonce, repetition: false, modificateurs: DrapeauxMac.versModificateurs(e.flags.rawValue))
        default:
            guard type.rawValue == typeSystemDefined, let ns = NSEvent(cgEvent: e), ns.subtype.rawValue == 8,
                  let d = TableTouchesSysteme.decoderData1(ns.data1), let usage = TableTouchesSysteme.usage(pourTypeNX: d.nx) else { return nil }
            return .toucheSysteme(ToucheSysteme(usage: usage, enfonce: d.enfonce, repetition: d.repetition))
        }
    }

    /// Injection neutre → CGEvent(s) prêts à poster (marqués). Séparé de l'envoi pour être testable.
    public static func fabriquer(_ i: Injection, source: CGEventSource?) -> [CGEvent] {
        var evenements: [CGEvent] = []
        switch i {
        case .mouvement(let p, let d, let boutons):
            let (type, bouton): (CGEventType, CGMouseButton) =
                if boutons.contains(.gauche) { (.leftMouseDragged, .left) }
                else if boutons.contains(.droit) { (.rightMouseDragged, .right) }
                else if let b = boutons.first { (.otherMouseDragged, CGMouseButton(rawValue: UInt32(b.rawValue)) ?? .center) }
                else { (.mouseMoved, .left) }
            if let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: bouton) {
                e.setDoubleValueField(.mouseEventDeltaX, value: d.x)
                e.setDoubleValueField(.mouseEventDeltaY, value: d.y)
                evenements.append(e)
            }
        case .bouton(let b, let enfonce, let nbClics, let p):
            let type: CGEventType = switch b {
            case .gauche: enfonce ? .leftMouseDown : .leftMouseUp
            case .droit: enfonce ? .rightMouseDown : .rightMouseUp
            default: enfonce ? .otherMouseDown : .otherMouseUp
            }
            let bouton = CGMouseButton(rawValue: UInt32(b.rawValue)) ?? .center
            if let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: bouton) {
                e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, nbClics)))
                e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b.rawValue))
                evenements.append(e)
            }
        case .defilement(let d, _):
            let unites: CGScrollEventUnit = d.continu ? .pixel : .line
            // Borné avant conversion : une valeur énorme venue du réseau ferait planter `Int32(_:)`.
            let borne = { (v: Float) in Int32(Swift.max(-10_000, Swift.min(10_000, v.rounded()))) }
            let r1 = d.continu ? d.dyPoints : d.dyLignes, r2 = d.continu ? d.dxPoints : d.dxLignes
            if let e = CGEvent(scrollWheelEvent2Source: source, units: unites, wheelCount: 2,
                               wheel1: borne(r1), wheel2: borne(r2), wheel3: 0) {
                e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(d.dyPoints))
                e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(d.dxPoints))
                e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(d.dyLignes))
                e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(d.dxLignes))
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: d.continu ? 1 : 0)
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: PhasesMac.quartz(depuis: d.phase))
                e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: PhasesMac.quartz(depuis: d.inertie))
                evenements.append(e)
            }
        case .touche(let usage, let enfonce, let repetition, let mods):
            guard let code = TableTouchesMac.codeMac(pourUsage: usage),
                  let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: enfonce) else { break }
            e.flags = CGEventFlags(rawValue: DrapeauxMac.depuisModificateurs(mods))
            if CodeTouche.estModificateur(usage) { e.type = .flagsChanged }
            if repetition { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            evenements.append(e)
        case .toucheSysteme(let t):
            guard let nx = TableTouchesSysteme.typeNX(pourUsage: t.usage) else { break }
            let ns = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: t.enfonce ? 0xA00 : 0xB00),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: TableTouchesSysteme.encoderData1(nx: nx, enfonce: t.enfonce, repetition: t.repetition), data2: -1)
            if let e = ns?.cgEvent { evenements.append(e) }
        }
        for e in evenements { e.setIntegerValueField(.eventSourceUserData, value: MarqueurInjection.valeur) }
        return evenements
    }
}
#endif
