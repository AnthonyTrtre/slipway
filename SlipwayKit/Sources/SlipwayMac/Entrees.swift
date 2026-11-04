#if os(macOS)
import AppKit
import CoreGraphics
import Synchronization
import SlipwayCoeur
import SlipwayMoteur

/// Capture des entrées physiques par un CGEventTap actif (il peut supprimer les événements), sur un fil dédié
/// avec sa propre boucle d'exécution (jamais le fil principal). La fonction de rappel ne fait que convertir
/// l'événement et appeler le gestionnaire (le moteur), qui répond en quelques microsecondes.
public final class CaptureEvenements: @unchecked Sendable {
    /// Rend vrai pour supprimer l'événement localement.
    public typealias Gestionnaire = @Sendable (EvenementLocal) -> Bool

    private let gestionnaire: Gestionnaire
    private let apresMouvementAvale: (@Sendable () -> Void)?
    /// Les objets CoreFoundation ne sont pas `Sendable` ; ils ne sont touchés que sous verrou ou par des API sûres entre fils.
    private struct Boite<T>: @unchecked Sendable { let valeur: T }
    private struct Etat {
        var tap: Boite<CFMachPort>?
        var boucle: Boite<CFRunLoop>?
        var reactivations = 0
    }
    private let etat = Mutex(Etat())

    /// `apresMouvementAvale` : appelé quand un mouvement part vers un autre Mac (le curseur local y est ramené).
    public init(apresMouvementAvale: (@Sendable () -> Void)? = nil, gestionnaire: @escaping Gestionnaire) {
        self.gestionnaire = gestionnaire
        self.apresMouvementAvale = apresMouvementAvale
    }

    /// Nombre de fois où macOS a désactivé le tap (rappel trop lent ou action de l'utilisateur) et où on l'a réactivé.
    public var reactivations: Int { etat.withLock { $0.reactivations } }
    public var estActive: Bool { etat.withLock { $0.tap.map { CGEvent.tapIsEnabled(tap: $0.valeur) } ?? false } }

    /// Démarre la capture. Échoue (rend faux) sans l'autorisation Accessibilité / Surveillance des entrées.
    @discardableResult
    public func demarrer() -> Bool {
        if etat.withLock({ $0.tap != nil }) { return true }
        let rappel: CGEventTapCallBack = { _, type, evenement, info in
            guard let info else { return Unmanaged.passUnretained(evenement) }
            let capture = Unmanaged<CaptureEvenements>.fromOpaque(info).takeUnretainedValue()
            return capture.traiter(type: type, evenement: evenement)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: ConversionEvenements.masque, callback: rappel,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let boite = Boite(valeur: tap)
        etat.withLock { $0.tap = boite }
        let fil = Thread { [self] in
            let tap = boite.valeur
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
            let boucle = CFRunLoopGetCurrent()
            etat.withLock { $0.boucle = Boite(valeur: boucle!) }
            CFRunLoopAddSource(boucle, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        fil.name = "Slipway capture"
        fil.qualityOfService = .userInteractive
        fil.start()
        return true
    }

    public func arreter() {
        let (tap, boucle) = etat.withLock { e in defer { e.tap = nil; e.boucle = nil }; return (e.tap, e.boucle) }
        if let tap {
            CGEvent.tapEnable(tap: tap.valeur, enable: false)
            CFMachPortInvalidate(tap.valeur)
        }
        if let boucle { CFRunLoopStop(boucle.valeur) }
    }

    private func traiter(type: CGEventType, evenement: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS coupe un tap trop lent : on le réarme tout de suite (et on le compte pour le diagnostic).
            let tap = etat.withLock { e -> Boite<CFMachPort>? in e.reactivations += 1; return e.tap }
            if let tap { CGEvent.tapEnable(tap: tap.valeur, enable: true) }
            return Unmanaged.passUnretained(evenement)
        }
        if ConversionEvenements.estInjecteParSlipway(evenement) { return Unmanaged.passUnretained(evenement) }
        guard let e = ConversionEvenements.versEvenementLocal(evenement, type: type) else { return Unmanaged.passUnretained(evenement) }
        guard gestionnaire(e) else { return Unmanaged.passUnretained(evenement) }
        if case .mouvement = e { apresMouvementAvale?() }
        return nil
    }
}

/// Injection immédiate (CGEventPost), sans file d'attente : chaque message reçu est posté à son arrivée.
public final class InjecteurMac: InjecteurEntrees, @unchecked Sendable {
    private let source: CGEventSource?

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Par défaut, un événement synthétique gèle la souris locale 0,25 s : on supprime ce délai.
        source?.localEventsSuppressionInterval = 0
    }

    public func injecter(_ injection: Injection) {
        for e in ConversionEvenements.fabriquer(injection, source: source) { e.post(tap: .cghidEventTap) }
    }
}

/// Curseur local : bloqué (et masqué si macOS le permet) pendant qu'on pilote un autre Mac, puis remis à l'endroit
/// exact de retour. macOS n'honore pas toujours le gel (`CGAssociateMouseAndMouseCursorPosition`) ni le masquage pour
/// une app de barre de menus en arrière-plan : le curseur suivait alors la souris sur ce Mac. Chaque mouvement parti
/// vers l'autre Mac ramène donc le curseur local à son point de sortie (`maintenir`). Le mouvement envoyé vient des
/// deltas de l'événement, il n'est pas touché.
public final class CurseurMac: CurseurLocal, @unchecked Sendable {
    private let masque = Mutex(false)
    private let gele = Mutex<CGPoint?>(nil)

    public init() {}

    public func figer() {
        gele.withLock { $0 = CGEvent(source: nil)?.location }
        CGAssociateMouseAndMouseCursorPosition(0)
        let doitMasquer = masque.withLock { m -> Bool in defer { m = true }; return !m }
        if doitMasquer { CGDisplayHideCursor(CGMainDisplayID()) }
    }

    /// Pendant le pilotage d'un autre Mac : remet le curseur local à son point de sortie s'il a bougé.
    public func maintenir() {
        guard let p = gele.withLock({ $0 }), let ici = CGEvent(source: nil)?.location, ici != p else { return }
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(0)   // réaffirme le gel et lève le délai qui suit un déplacement forcé
    }

    public func liberer(a point: Point) {
        gele.withLock { $0 = nil }
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        let doitAfficher = masque.withLock { m -> Bool in defer { m = false }; return m }
        if doitAfficher { CGDisplayShowCursor(CGMainDisplayID()) }
    }

    /// Filet de sécurité (arrêt de l'app) : jamais de curseur invisible ou bloqué.
    public func restaurer() {
        gele.withLock { $0 = nil }
        CGAssociateMouseAndMouseCursorPosition(1)
        let doitAfficher = masque.withLock { m -> Bool in defer { m = false }; return m }
        if doitAfficher { CGDisplayShowCursor(CGMainDisplayID()) }
    }
}

/// Écrans de ce Mac, en points dans l'espace global Quartz.
public enum EcransMac {
    public static func lister() -> [Ecran] {
        var nombre: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &nombre) == .success, nombre > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(nombre))
        guard CGGetActiveDisplayList(nombre, &ids, &nombre) == .success else { return [] }
        return ids.prefix(Int(nombre))
            .filter { CGDisplayMirrorsDisplay($0) == 0 }   // un écran recopié n'ajoute pas de surface
            .map { id in
                let b = CGDisplayBounds(id)
                var echelle = 1.0
                if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 { echelle = Double(mode.pixelWidth) / Double(mode.width) }
                return Ecran(id: id, cadre: Rect(x: Double(b.origin.x), y: Double(b.origin.y), largeur: Double(b.width), hauteur: Double(b.height)),
                             echelle: echelle, principal: CGDisplayIsMain(id) != 0)
            }
    }

    /// Position actuelle du curseur (espace global Quartz).
    public static func positionCurseur() -> Point {
        let p = CGEvent(source: nil)?.location ?? .zero
        return Point(x: Double(p.x), y: Double(p.y))
    }
}
#endif
