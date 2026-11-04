/// État des modificateurs dans le protocole : mêmes 8 premiers bits que le rapport clavier HID « boot »
/// (gauche puis droite : Ctrl, Maj, Alt/Option, GUI/Cmd), plus Verr. Maj. et Fn. Indépendant de macOS.
public struct Modificateurs: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let ctrlGauche = Modificateurs(rawValue: 1 << 0)
    public static let majGauche = Modificateurs(rawValue: 1 << 1)
    public static let optionGauche = Modificateurs(rawValue: 1 << 2)
    public static let cmdGauche = Modificateurs(rawValue: 1 << 3)
    public static let ctrlDroit = Modificateurs(rawValue: 1 << 4)
    public static let majDroit = Modificateurs(rawValue: 1 << 5)
    public static let optionDroit = Modificateurs(rawValue: 1 << 6)
    public static let cmdDroit = Modificateurs(rawValue: 1 << 7)
    public static let verrMaj = Modificateurs(rawValue: 1 << 8)
    public static let fn = Modificateurs(rawValue: 1 << 9)

    public static let ctrl: Modificateurs = [.ctrlGauche, .ctrlDroit]
    public static let maj: Modificateurs = [.majGauche, .majDroit]
    public static let option: Modificateurs = [.optionGauche, .optionDroit]
    public static let cmd: Modificateurs = [.cmdGauche, .cmdDroit]

    /// Vrai si au moins un côté de chaque groupe demandé est enfoncé, et aucun autre groupe (hors Verr. Maj. et Fn).
    public func correspondExactement(a groupes: [Modificateurs]) -> Bool {
        let tousGroupes: [Modificateurs] = [.ctrl, .maj, .option, .cmd]
        for g in tousGroupes {
            let attendu = groupes.contains(g)
            if attendu != !self.intersection(g).isEmpty { return false }
        }
        return true
    }

    /// Le modificateur correspondant à un usage HID 0xE0…0xE7, sinon nil.
    public static func pourUsage(_ usage: UInt16) -> Modificateurs? {
        switch usage {
        case 0xE0...0xE7: Modificateurs(rawValue: 1 << UInt32(usage - 0xE0))
        case CodeTouche.verrMaj: .verrMaj
        case CodeTouche.fn: .fn
        default: nil
        }
    }
}

/// Drapeaux d'événement Quartz (`CGEventFlags`), en valeurs brutes pour rester testables hors macOS.
/// Les bits « par côté » (NX_DEVICE…) sont ceux que macOS place dans les 16 bits de poids faible.
public enum DrapeauxMac {
    public static let verrMaj: UInt64 = 0x0001_0000      // maskAlphaShift
    public static let maj: UInt64 = 0x0002_0000          // maskShift
    public static let ctrl: UInt64 = 0x0004_0000         // maskControl
    public static let option: UInt64 = 0x0008_0000      // maskAlternate
    public static let cmd: UInt64 = 0x0010_0000          // maskCommand
    public static let paveNumerique: UInt64 = 0x0020_0000 // maskNumericPad
    public static let aide: UInt64 = 0x0040_0000         // maskHelp
    public static let fn: UInt64 = 0x0080_0000           // maskSecondaryFn

    public static let ctrlGauche: UInt64 = 0x0000_0001
    public static let majGauche: UInt64 = 0x0000_0002
    public static let majDroit: UInt64 = 0x0000_0004
    public static let cmdGauche: UInt64 = 0x0000_0008
    public static let cmdDroit: UInt64 = 0x0000_0010
    public static let optionGauche: UInt64 = 0x0000_0020
    public static let optionDroit: UInt64 = 0x0000_0040
    public static let ctrlDroit: UInt64 = 0x0000_2000

    /// Drapeaux Quartz → modificateurs du protocole. Si macOS n'a pas fourni les bits par côté (événement
    /// synthétique), on attribue le modificateur au côté gauche.
    public static func versModificateurs(_ d: UInt64) -> Modificateurs {
        var m: Modificateurs = []
        func groupe(_ general: UInt64, _ gauche: UInt64, _ droit: UInt64, _ mg: Modificateurs, _ md: Modificateurs) {
            guard d & general != 0 else { return }
            if d & gauche != 0 { m.insert(mg) }
            if d & droit != 0 { m.insert(md) }
            if d & (gauche | droit) == 0 { m.insert(mg) }
        }
        groupe(ctrl, ctrlGauche, ctrlDroit, .ctrlGauche, .ctrlDroit)
        groupe(maj, majGauche, majDroit, .majGauche, .majDroit)
        groupe(option, optionGauche, optionDroit, .optionGauche, .optionDroit)
        groupe(cmd, cmdGauche, cmdDroit, .cmdGauche, .cmdDroit)
        if d & verrMaj != 0 { m.insert(.verrMaj) }
        if d & fn != 0 { m.insert(.fn) }
        return m
    }

    /// Modificateurs du protocole → drapeaux Quartz (bits généraux et bits par côté).
    public static func depuisModificateurs(_ m: Modificateurs) -> UInt64 {
        var d: UInt64 = 0
        if m.contains(.ctrlGauche) { d |= ctrl | ctrlGauche }
        if m.contains(.ctrlDroit) { d |= ctrl | ctrlDroit }
        if m.contains(.majGauche) { d |= maj | majGauche }
        if m.contains(.majDroit) { d |= maj | majDroit }
        if m.contains(.optionGauche) { d |= option | optionGauche }
        if m.contains(.optionDroit) { d |= option | optionDroit }
        if m.contains(.cmdGauche) { d |= cmd | cmdGauche }
        if m.contains(.cmdDroit) { d |= cmd | cmdDroit }
        if m.contains(.verrMaj) { d |= verrMaj }
        if m.contains(.fn) { d |= fn }
        return d
    }

    /// Pour un événement `flagsChanged` : la touche modificatrice `codeMac` vient-elle d'être enfoncée ?
    /// macOS n'envoie qu'un seul type d'événement pour l'appui et le relâchement ; on lit l'état dans les drapeaux.
    public static func estEnfoncee(codeMac: UInt16, drapeaux d: UInt64) -> Bool? {
        guard let usage = TableTouchesMac.usage(pourCodeMac: codeMac), let mod = Modificateurs.pourUsage(usage) else { return nil }
        return versModificateurs(d).contains(mod)
    }
}
