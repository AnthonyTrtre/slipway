import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import SlipwayCoeur

/// Source d'aléa injectable : le système en production, une suite déterministe dans les tests
/// (vecteurs de référence pour le futur client Windows).
public protocol SourceAlea: Sendable {
    func octets(_ n: Int) -> [UInt8]
}

public struct AleaSysteme: SourceAlea {
    public init() {}
    public func octets(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }
}

public enum ErreurSecurite: Error, Equatable, Sendable {
    case cleInvalide
    case engagementInvalide
    case signatureInvalide
    case messageInattendu(String)
    case dechiffrementImpossible
    case rejeu
    case datagrammeInvalide
    case versionIncompatible(UInt8)
}

/// Identité durable d'un Mac : paire de clés Ed25519. La clé privée vit dans le Trousseau (adaptateur macOS).
public struct Identite: Sendable {
    let cle: Curve25519.Signing.PrivateKey

    public init() { cle = Curve25519.Signing.PrivateKey() }

    public init(brut: [UInt8]) throws(ErreurSecurite) {
        do { cle = try Curve25519.Signing.PrivateKey(rawRepresentation: brut) } catch { throw .cleInvalide }
    }

    /// Les 32 octets de la clé privée (à ranger dans le Trousseau, jamais dans un fichier ni un journal).
    public var brut: [UInt8] { Array(cle.rawRepresentation) }
    public var clePublique: [UInt8] { Array(cle.publicKey.rawRepresentation) }
    public var id: IdPair { IdPair(cleIdentite: clePublique) }

    public func signer(_ message: [UInt8]) throws(ErreurSecurite) -> [UInt8] {
        do { return Array(try cle.signature(for: message)) } catch { throw .cleInvalide }
    }

    public static func verifier(signature: [UInt8], message: [UInt8], clePublique: [UInt8]) -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: clePublique) else { return false }
        return pub.isValidSignature(signature, for: message)
    }
}

/// Fonctions cryptographiques de la spécification (voir docs/protocole.md, section « Chiffrement »).
public enum Derivation {
    public static func sha256(_ octets: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: octets)) }

    /// HKDF-SHA256(ikm, sel, "SLPW v1 " + étiquette, n).
    public static func hkdf(_ ikm: [UInt8], sel: [UInt8], etiquette: String, octets n: Int) -> [UInt8] {
        let cle = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: sel,
                                         info: Array("SLPW v1 \(etiquette)".utf8), outputByteCount: n)
        return cle.withUnsafeBytes { Array($0) }
    }

    /// Clé publique X25519 correspondant à une clé privée brute.
    public static func clePubliqueX25519(privee: [UInt8]) throws(ErreurSecurite) -> [UInt8] {
        do { return Array(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privee).publicKey.rawRepresentation) } catch {
            throw .cleInvalide
        }
    }

    /// Secret partagé X25519 brut (32 octets).
    public static func secretPartage(privee: [UInt8], publiquePair: [UInt8]) throws(ErreurSecurite) -> [UInt8] {
        do {
            let p = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privee)
            let q = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publiquePair)
            return try p.sharedSecretFromKeyAgreement(with: q).withUnsafeBytes { Array($0) }
        } catch { throw .cleInvalide }
    }

    /// Code de vérification à 6 chiffres : les 4 premiers octets (gros-boutiste) modulo 1 000 000, avec zéros à gauche.
    public static func codeSixChiffres(_ octets: [UInt8]) -> String {
        let v = octets.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let s = String(v)
        return String(repeating: "0", count: 6 - s.count) + s
    }

    /// Nonce ChaCha20-Poly1305 de 12 octets : 4 octets nuls puis le compteur 64 bits petit-boutiste.
    public static func nonce(_ compteur: UInt64) -> [UInt8] {
        var e = EcrivainOctets(capacite: 12)
        e.u32(0)
        e.u64(compteur)
        return e.octets
    }

    public static func sceller(_ clair: [UInt8], cle: [UInt8], compteur: UInt64, donneesAssociees: [UInt8] = []) -> [UInt8] {
        // Ne peut échouer qu'avec une clé ou un nonce de mauvaise taille, ce que nos appelants garantissent.
        let boite = try! ChaChaPoly.seal(clair, using: SymmetricKey(data: cle), nonce: try! ChaChaPoly.Nonce(data: nonce(compteur)),
                                         authenticating: donneesAssociees)
        return Array(boite.ciphertext) + Array(boite.tag)
    }

    public static func ouvrir(_ scelle: [UInt8], cle: [UInt8], compteur: UInt64, donneesAssociees: [UInt8] = []) throws(ErreurSecurite) -> [UInt8] {
        guard scelle.count >= 16 else { throw .dechiffrementImpossible }
        do {
            let boite = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce(compteur)),
                                                 ciphertext: scelle.dropLast(16), tag: scelle.suffix(16))
            return Array(try ChaChaPoly.open(boite, using: SymmetricKey(data: cle), authenticating: donneesAssociees))
        } catch { throw .dechiffrementImpossible }
    }
}
