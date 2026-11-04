import SlipwayCoeur

/// Canal fiable (TCP) : chaque enregistrement = trame scellée (texte chiffré ‖ étiquette de 16 octets).
/// Les compteurs sont implicites (0, 1, 2… dans chaque sens) : TCP garantit l'ordre, tout écart est une attaque.
public struct ScelleurFlux: Sendable {
    private let cleEnvoi: [UInt8]
    private let cleReception: [UInt8]
    public private(set) var compteurEnvoi: UInt64 = 0
    public private(set) var compteurReception: UInt64 = 0

    public init(materiel: MaterielSession) {
        cleEnvoi = materiel.cleEnvoiFlux
        cleReception = materiel.cleReceptionFlux
    }

    public mutating func sceller(_ trame: [UInt8]) -> [UInt8] {
        defer { compteurEnvoi += 1 }
        return Derivation.sceller(trame, cle: cleEnvoi, compteur: compteurEnvoi)
    }

    public mutating func ouvrir(_ enregistrement: [UInt8]) throws(ErreurSecurite) -> [UInt8] {
        let clair = try Derivation.ouvrir(enregistrement, cle: cleReception, compteur: compteurReception)
        compteurReception += 1
        return clair
    }
}

/// Fenêtre anti-rejeu de 64 compteurs (comme IPsec/DTLS) : accepte un datagramme en retard s'il est récent
/// et jamais vu, refuse tout doublon et tout ce qui est plus vieux que la fenêtre.
public struct FenetreAntiRejeu: Equatable, Sendable {
    public static let taille: UInt64 = 64
    private var plusGrand: UInt64?
    private var masque: UInt64 = 0   // bit i = compteur (plusGrand - i) déjà vu

    public init() {}

    public func estAcceptable(_ c: UInt64) -> Bool {
        guard let max = plusGrand else { return true }
        if c > max { return true }
        let ecart = max - c
        guard ecart < Self.taille else { return false }
        return masque & (1 << ecart) == 0
    }

    /// À appeler seulement après authentification réussie du datagramme.
    public mutating func marquer(_ c: UInt64) {
        guard let max = plusGrand else { plusGrand = c; masque = 1; return }
        if c > max {
            let decalage = c - max
            masque = decalage >= Self.taille ? 1 : (masque << decalage) | 1
            plusGrand = c
        } else {
            let ecart = max - c
            if ecart < Self.taille { masque |= 1 << ecart }
        }
    }
}

/// Canal temps réel (UDP) : chaque datagramme est autonome et peut être perdu ou désordonné.
///
///     version (u8 = 1) | id du canal (8 octets) | compteur (u64) | trame chiffrée | étiquette (16 octets)
///
/// Les 17 premiers octets sont authentifiés (données associées) sans être chiffrés.
public struct ScelleurDatagrammes: Sendable {
    public static let version: UInt8 = 1
    public static let tailleEntete = 17
    private let cleEnvoi: [UInt8]
    private let cleReception: [UInt8]
    public let idCanal: [UInt8]
    public private(set) var compteurEnvoi: UInt64 = 0
    public private(set) var fenetre = FenetreAntiRejeu()
    public private(set) var rejetes = 0

    public init(materiel: MaterielSession) {
        cleEnvoi = materiel.cleEnvoiDatagrammes
        cleReception = materiel.cleReceptionDatagrammes
        idCanal = materiel.idCanalTempsReel
    }

    public mutating func sceller(_ trame: [UInt8]) -> [UInt8] {
        defer { compteurEnvoi += 1 }
        var entete = EcrivainOctets(capacite: Self.tailleEntete + trame.count + 16)
        entete.u8(Self.version)
        entete.brut(idCanal)
        entete.u64(compteurEnvoi)
        return entete.octets + Derivation.sceller(trame, cle: cleEnvoi, compteur: compteurEnvoi, donneesAssociees: entete.octets)
    }

    /// Lit l'identifiant de canal d'un datagramme sans l'ouvrir (pour retrouver la bonne session).
    public static func idCanal(de datagramme: [UInt8]) -> [UInt8]? {
        guard datagramme.count >= tailleEntete + 16, datagramme[0] == version else { return nil }
        return Array(datagramme[1..<9])
    }

    public mutating func ouvrir(_ datagramme: [UInt8]) throws(ErreurSecurite) -> [UInt8] {
        guard Self.idCanal(de: datagramme) == idCanal else { rejetes += 1; throw .datagrammeInvalide }
        var l = LecteurOctets(datagramme, position: 9)
        guard let compteur = try? l.u64() else { rejetes += 1; throw .datagrammeInvalide }
        guard fenetre.estAcceptable(compteur) else { rejetes += 1; throw .rejeu }
        let clair: [UInt8]
        do {
            clair = try Derivation.ouvrir(Array(datagramme[Self.tailleEntete...]), cle: cleReception, compteur: compteur,
                                          donneesAssociees: Array(datagramme[..<Self.tailleEntete]))
        } catch {
            rejetes += 1
            throw error
        }
        fenetre.marquer(compteur)
        return clair
    }
}
