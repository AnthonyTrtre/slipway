#if os(macOS)
import AppKit
import ApplicationServices
import Carbon
import Foundation
import Security
import Synchronization
import SlipwayCoeur
import SlipwaySecurite
import SlipwayMoteur

/// Identité Ed25519 de ce Mac, rangée dans le Trousseau (jamais dans un fichier ni un journal).
public enum Trousseau {
    static let service = "fr.anthony.slipway"
    static let compte = "identite"

    public enum Erreur: Error { case trousseau(OSStatus) }

    public static func chargerOuCreerIdentite() throws -> Identite {
        let requete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compte,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var resultat: CFTypeRef?
        let statut = SecItemCopyMatching(requete as CFDictionary, &resultat)
        if statut == errSecSuccess, let donnees = resultat as? Data, let identite = try? Identite(brut: [UInt8](donnees)) {
            return identite
        }
        guard statut == errSecItemNotFound else { throw Erreur.trousseau(statut) }
        let identite = Identite()
        let ajout: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compte,
            kSecAttrLabel as String: "Slipway : identité de ce Mac",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(identite.brut),
        ]
        let s = SecItemAdd(ajout as CFDictionary, nil)
        guard s == errSecSuccess else { throw Erreur.trousseau(s) }
        return identite
    }

    /// Données d'un autre élément de Slipway (nil s'il n'existe pas).
    static func lire(compte: String) -> Data? {
        let requete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: compte,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var resultat: CFTypeRef?
        return SecItemCopyMatching(requete as CFDictionary, &resultat) == errSecSuccess ? resultat as? Data : nil
    }

    static func ecrire(_ donnees: Data, compte: String, libelle: String) {
        let cle: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: compte]
        if SecItemUpdate(cle as CFDictionary, [kSecValueData as String: donnees] as CFDictionary) == errSecItemNotFound {
            var ajout = cle
            ajout[kSecAttrLabel as String] = libelle
            ajout[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ajout[kSecValueData as String] = donnees
            SecItemAdd(ajout as CFDictionary, nil)
        }
    }
}

/// Pairs appairés : clé publique d'identité épinglée et nom. Rangés dans le Trousseau, pas dans les préférences :
/// n'importe quel programme local peut écrire les préférences (`defaults write`) et se serait fait passer pour un
/// Mac connu. Les anciennes préférences sont migrées une fois puis effacées.
public final class MagasinPairsMac: MagasinPairs, @unchecked Sendable {
    private let defaults: UserDefaults
    private let cle = "pairs.epingles"
    private let verrou = Mutex<[String: String]?>(nil)

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// À n'utiliser que sous `verrou` (la valeur en mémoire y est gardée).
    private func charger(_ memoire: inout [String: String]?) -> [String: String] {
        if let m = memoire { return m }
        var t = (Trousseau.lire(compte: cle)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        if t == nil, let anciens = defaults.dictionary(forKey: cle) as? [String: String] {
            t = anciens
            enregistrer(anciens, &memoire)
        }
        if Trousseau.lire(compte: cle) != nil { defaults.removeObject(forKey: cle) }   // effacées une fois copiées
        memoire = t ?? [:]
        return memoire!
    }

    private func enregistrer(_ t: [String: String], _ memoire: inout [String: String]?) {
        if let d = try? JSONEncoder().encode(t) { Trousseau.ecrire(d, compte: cle, libelle: "Slipway : Mac appairés") }
        memoire = t
    }

    private var table: [String: String] {
        get { verrou.withLock { charger(&$0) } }
        set { verrou.withLock { enregistrer(newValue, &$0) } }
    }

    public func estConnu(_ clePublique: [UInt8]) -> Bool { table[Hex.encoder(clePublique)] != nil }

    public func estConnu(id: IdPair) -> Bool {
        table.keys.contains { IdPair(cleIdentite: Hex.decoder($0) ?? []) == id }
    }

    public func memoriser(clePublique: [UInt8], nom: String) {
        verrou.withLock { m in var t = charger(&m); t[Hex.encoder(clePublique)] = nom; enregistrer(t, &m) }
    }

    public func oublier(id: IdPair) {
        verrou.withLock { m in
            enregistrer(charger(&m).filter { IdPair(cleIdentite: Hex.decoder($0.key) ?? []) != id }, &m)
        }
        adresses[id.rawValue] = nil
    }

    /// Dernière adresse IPv4 qui a marché pour chaque pair : secours quand Bonjour ne le trouve plus.
    private var adresses: [String: String] {
        get { defaults.dictionary(forKey: "pairs.adresses") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "pairs.adresses") }
    }

    public func adresse(id: IdPair) -> String? { adresses[id.rawValue] }

    public func memoriserAdresse(_ ip: String, id: IdPair) {
        if adresses[id.rawValue] != ip { adresses[id.rawValue] = ip }
    }

    public var liste: [(id: IdPair, nom: String)] {
        table.map { (IdPair(cleIdentite: Hex.decoder($0.key) ?? []), $0.value) }.sorted { $0.nom < $1.nom }
    }
}

/// Autorisations TCC (Accessibilité pour le tap actif et l'injection, Surveillance des entrées pour le clavier).
public enum Permissions {
    public static var accessibilite: Bool { AXIsProcessTrusted() }
    public static var surveillanceEntrees: Bool { CGPreflightListenEventAccess() }
    public static var injection: Bool { CGPreflightPostEventAccess() }
    public static var toutes: Bool { accessibilite && surveillanceEntrees && injection }

    /// Affiche les invites système (une seule fois par autorisation ; ensuite il faut passer par Réglages).
    public static func demander() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()
    }

    public static func ouvrirReglagesAccessibilite() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    public static func ouvrirReglagesSurveillance() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
    }
}

/// Saisie sécurisée : quand un champ mot de passe a le focus sur CE Mac, macOS coupe le clavier vers tous les taps.
/// On ne peut pas la contourner ; on l'affiche clairement avec le nom de l'app responsable.
public enum SaisieSecurisee {
    public static var active: Bool { IsSecureEventInputEnabled() }

    public static var applicationResponsable: String? {
        guard active, let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int32 ?? (session["kCGSSessionSecureInputPID"] as? Int).map(Int32.init) else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "processus \(pid)"
    }
}
#endif
