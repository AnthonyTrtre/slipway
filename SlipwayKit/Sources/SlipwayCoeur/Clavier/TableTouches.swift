/// Codes de touche du protocole : usages HID de la page clavier (0x07), langue commune entre macOS et
/// (plus tard) Windows. Seule la touche Fn d'Apple n'a pas d'usage standard : code étendu 0x0300.
public enum CodeTouche {
    public static let a: UInt16 = 0x04
    public static let c: UInt16 = 0x06
    public static let l: UInt16 = 0x0F
    public static let v: UInt16 = 0x19
    public static let x: UInt16 = 0x1B
    public static let chiffre1: UInt16 = 0x1E
    public static let chiffre9: UInt16 = 0x26
    public static let entree: UInt16 = 0x28
    public static let echap: UInt16 = 0x29
    public static let tab: UInt16 = 0x2B
    public static let espace: UInt16 = 0x2C
    public static let verrMaj: UInt16 = 0x39
    public static let ctrlGauche: UInt16 = 0xE0
    public static let majGauche: UInt16 = 0xE1
    public static let optionGauche: UInt16 = 0xE2
    public static let cmdGauche: UInt16 = 0xE3
    public static let ctrlDroit: UInt16 = 0xE4
    public static let majDroit: UInt16 = 0xE5
    public static let optionDroit: UInt16 = 0xE6
    public static let cmdDroit: UInt16 = 0xE7
    /// Touche Fn / globe d'Apple (pas d'usage HID standard dans la page 0x07).
    public static let fn: UInt16 = 0x0300

    public static func estModificateur(_ usage: UInt16) -> Bool { Modificateurs.pourUsage(usage) != nil }
}

/// Correspondance code de touche virtuel macOS (`CGKeyCode`, kVK_…) ↔ usage HID.
/// Table pure, bijective sur les touches listées (aller-retour testé).
public enum TableTouchesMac {
    /// (code Mac, usage HID). Les noms kVK_ sont rappelés en commentaire.
    public static let paires: [(mac: UInt16, hid: UInt16)] = [
        (0x00, 0x04), (0x0B, 0x05), (0x08, 0x06), (0x02, 0x07), (0x0E, 0x08), (0x03, 0x09), // A B C D E F
        (0x05, 0x0A), (0x04, 0x0B), (0x22, 0x0C), (0x26, 0x0D), (0x28, 0x0E), (0x25, 0x0F), // G H I J K L
        (0x2E, 0x10), (0x2D, 0x11), (0x1F, 0x12), (0x23, 0x13), (0x0C, 0x14), (0x0F, 0x15), // M N O P Q R
        (0x01, 0x16), (0x11, 0x17), (0x20, 0x18), (0x09, 0x19), (0x0D, 0x1A), (0x07, 0x1B), // S T U V W X
        (0x10, 0x1C), (0x06, 0x1D),                                                          // Y Z
        (0x12, 0x1E), (0x13, 0x1F), (0x14, 0x20), (0x15, 0x21), (0x17, 0x22), (0x16, 0x23), // 1 2 3 4 5 6
        (0x1A, 0x24), (0x1C, 0x25), (0x19, 0x26), (0x1D, 0x27),                              // 7 8 9 0
        (0x24, 0x28), (0x35, 0x29), (0x33, 0x2A), (0x30, 0x2B), (0x31, 0x2C),                // Retour Échap Effacer Tab Espace
        (0x1B, 0x2D), (0x18, 0x2E), (0x21, 0x2F), (0x1E, 0x30), (0x2A, 0x31),                // - = [ ] \
        (0x29, 0x33), (0x27, 0x34), (0x32, 0x35), (0x2B, 0x36), (0x2F, 0x37), (0x2C, 0x38),  // ; ' ` , . /
        (0x39, 0x39),                                                                        // Verr. Maj.
        (0x7A, 0x3A), (0x78, 0x3B), (0x63, 0x3C), (0x76, 0x3D), (0x60, 0x3E), (0x61, 0x3F),  // F1…F6
        (0x62, 0x40), (0x64, 0x41), (0x65, 0x42), (0x6D, 0x43), (0x67, 0x44), (0x6F, 0x45),  // F7…F12
        (0x72, 0x49), (0x73, 0x4A), (0x74, 0x4B), (0x75, 0x4C), (0x77, 0x4D), (0x79, 0x4E),  // Aide/Inser Début PgPréc Suppr Fin PgSuiv
        (0x7C, 0x4F), (0x7B, 0x50), (0x7D, 0x51), (0x7E, 0x52),                              // → ← ↓ ↑
        (0x47, 0x53), (0x4B, 0x54), (0x43, 0x55), (0x4E, 0x56), (0x45, 0x57), (0x4C, 0x58),  // Pavé : Effacer / * - + Entrée
        (0x53, 0x59), (0x54, 0x5A), (0x55, 0x5B), (0x56, 0x5C), (0x57, 0x5D), (0x58, 0x5E),  // Pavé 1…6
        (0x59, 0x5F), (0x5B, 0x60), (0x5C, 0x61), (0x52, 0x62), (0x41, 0x63),                // Pavé 7 8 9 0 .
        (0x0A, 0x64), (0x6E, 0x65), (0x51, 0x67),                                            // ISO § ou <>, Menu contextuel, Pavé =
        (0x69, 0x68), (0x6B, 0x69), (0x71, 0x6A), (0x6A, 0x6B), (0x40, 0x6C), (0x4F, 0x6D),  // F13…F18
        (0x50, 0x6E), (0x5A, 0x6F),                                                          // F19 F20
        (0x4A, 0x7F), (0x48, 0x80), (0x49, 0x81),                                            // Muet, Volume +, Volume -
        (0x5F, 0x85), (0x5E, 0x87), (0x5D, 0x89), (0x68, 0x90), (0x66, 0x91),                // JIS : , _ ¥ Kana Eisu
        (0x3B, 0xE0), (0x38, 0xE1), (0x3A, 0xE2), (0x37, 0xE3),                              // Ctrl Maj Option Cmd (gauche)
        (0x3E, 0xE4), (0x3C, 0xE5), (0x3D, 0xE6), (0x36, 0xE7),                              // Ctrl Maj Option Cmd (droite)
        (0x3F, CodeTouche.fn),                                                               // Fn
    ]

    private static let versHID: [UInt16: UInt16] = Dictionary(uniqueKeysWithValues: paires.map { ($0.mac, $0.hid) })
    private static let versMac: [UInt16: UInt16] = Dictionary(uniqueKeysWithValues: paires.map { ($0.hid, $0.mac) })

    public static func usage(pourCodeMac code: UInt16) -> UInt16? { versHID[code] }
    public static func codeMac(pourUsage usage: UInt16) -> UInt16? { versMac[usage] }
}

/// Touches système et média : usage HID de la page consommateur (0x0C) ↔ type NX_KEYTYPE de macOS
/// (événement `systemDefined`, sous-type 8).
public enum TableTouchesSysteme {
    public static let paires: [(nx: Int32, hid: UInt16)] = [
        (0, 0xE9),   // NX_KEYTYPE_SOUND_UP ↔ Volume +
        (1, 0xEA),   // NX_KEYTYPE_SOUND_DOWN ↔ Volume -
        (2, 0x6F),   // NX_KEYTYPE_BRIGHTNESS_UP ↔ Luminosité +
        (3, 0x70),   // NX_KEYTYPE_BRIGHTNESS_DOWN ↔ Luminosité -
        (7, 0xE2),   // NX_KEYTYPE_MUTE ↔ Muet
        (14, 0xB8),  // NX_KEYTYPE_EJECT ↔ Éjecter
        (16, 0xCD),  // NX_KEYTYPE_PLAY ↔ Lecture/Pause
        (17, 0xB5),  // NX_KEYTYPE_NEXT ↔ Piste suivante
        (18, 0xB6),  // NX_KEYTYPE_PREVIOUS ↔ Piste précédente
        (19, 0xB3),  // NX_KEYTYPE_FAST ↔ Avance rapide
        (20, 0xB4),  // NX_KEYTYPE_REWIND ↔ Retour rapide
        (21, 0x79),  // NX_KEYTYPE_ILLUMINATION_UP ↔ Rétroéclairage clavier +
        (22, 0x7A),  // NX_KEYTYPE_ILLUMINATION_DOWN ↔ Rétroéclairage clavier -
        (23, 0x7C),  // NX_KEYTYPE_ILLUMINATION_TOGGLE ↔ Rétroéclairage marche/arrêt
    ]

    private static let versHID: [Int32: UInt16] = Dictionary(uniqueKeysWithValues: paires.map { ($0.nx, $0.hid) })
    private static let versNX: [UInt16: Int32] = Dictionary(uniqueKeysWithValues: paires.map { ($0.hid, $0.nx) })

    public static func usage(pourTypeNX nx: Int32) -> UInt16? { versHID[nx] }
    public static func typeNX(pourUsage usage: UInt16) -> Int32? { versNX[usage] }

    /// Décode le champ `data1` d'un événement systemDefined de sous-type 8 :
    /// bits 16-31 = type NX, bits 8-15 = état (0x0A enfoncé, 0x0B relâché), bit 0 = répétition.
    public static func decoderData1(_ data1: Int) -> (nx: Int32, enfonce: Bool, repetition: Bool)? {
        let nx = Int32((data1 & 0xFFFF_0000) >> 16)
        let etat = (data1 & 0xFF00) >> 8
        guard etat == 0x0A || etat == 0x0B else { return nil }
        return (nx, etat == 0x0A, data1 & 0x1 != 0)
    }

    public static func encoderData1(nx: Int32, enfonce: Bool, repetition: Bool) -> Int {
        (Int(nx) << 16) | ((enfonce ? 0x0A : 0x0B) << 8) | (repetition ? 1 : 0)
    }
}

/// Phases de défilement : valeurs Quartz ↔ valeurs neutres du protocole.
public enum PhasesMac {
    /// `kCGScrollWheelEventScrollPhase` : 1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin.
    public static func phase(depuisQuartz v: Int64) -> PhaseDefilement {
        switch v {
        case 1: .debut
        case 2: .changement
        case 4: .fin
        case 8: .annule
        case 128: .peutCommencer
        default: .aucune
        }
    }

    public static func quartz(depuis p: PhaseDefilement) -> Int64 {
        switch p {
        case .aucune: 0
        case .debut: 1
        case .changement: 2
        case .fin: 4
        case .annule: 8
        case .peutCommencer: 128
        }
    }

    /// `kCGScrollWheelEventMomentumPhase` : 0 none, 1 begin, 2 continue, 3 end (mêmes valeurs que le protocole).
    public static func inertie(depuisQuartz v: Int64) -> PhaseInertie { PhaseInertie(rawValue: UInt8(clamping: v)) ?? .aucune }
    public static func quartz(depuis i: PhaseInertie) -> Int64 { Int64(i.rawValue) }
}
