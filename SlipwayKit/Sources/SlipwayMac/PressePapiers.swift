#if os(macOS)
import AppKit
import Foundation
import Synchronization
import os
import SlipwayCoeur
import SlipwayMoteur

private let tracesPP = Logger(subsystem: "fr.anthony.slipway", category: "presse-papiers")

/// Presse-papiers partagé : texte, images (PNG) et fichiers copiés dans le Finder (dossiers et apps compris).
/// On ne lit le contenu que si `changeCount` a bougé, et seulement après une copie ou une bascule. Lecture et écriture
/// passent par une file dédiée : archiver ou poser des centaines de Mo ne bloque ni l'interface ni le réseau.
public final class PressePapiersMac: PressePapiersLocal, @unchecked Sendable {
    private let rappel = Mutex<(@Sendable (Int, () -> ContenuPressePapiers?) -> Void)?>(nil)
    private let file = DispatchQueue(label: "fr.anthony.slipway.presse-papiers", qos: .userInitiated)
    /// Fichiers reçus, le temps qu'on les colle : seul le dernier envoi est gardé, tout est effacé au lancement.
    public let dossierRecus = FileManager.default.temporaryDirectory.appendingPathComponent("Slipway-recus", isDirectory: true)

    public init() { try? FileManager.default.removeItem(at: dossierRecus) }

    /// À relier au moteur une fois celui-ci créé : `{ moteur.compteurPressePapiers($0, lire: $1) }`.
    public func relier(_ r: @escaping @Sendable (Int, () -> ContenuPressePapiers?) -> Void) { rappel.withLock { $0 = r } }

    public func signalerChangementPossible() {
        // L'application qui copie écrit le presse-papiers un peu après le ⌘C : deux vérifications espacées.
        for delai in [0.15, 0.6] {
            file.asyncAfter(deadline: .now() + delai) { [weak self] in
                guard let r = self?.rappel.withLock({ $0 }) else { return }
                let pb = NSPasteboard.general
                r(pb.changeCount) { Self.lire(pb) }
            }
        }
    }

    static func lire(_ pb: NSPasteboard) -> ContenuPressePapiers? {
        let types = Set(pb.types ?? [])
        // Mots de passe copiés depuis un gestionnaire (types marqués « masqué » ou « éphémère ») : jamais envoyés.
        let prives: Set<NSPasteboard.PasteboardType> = [.init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")]
        guard types.isDisjoint(with: prives) else { return nil }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return LecteurFichiers.lot(urls).map { .fichiers($0) }
        }
        let texte = pb.string(forType: .string)
        // Un texte riche (Pages, Word) porte souvent aussi une image de l'extrait : c'est le texte qu'on veut.
        let texteVoulu = texte.map { !$0.isEmpty && (types.contains(.rtf) || types.contains(.html) || $0.contains(where: \.isWhitespace)) } ?? false
        if !texteVoulu, let image = imagePNG(pb) { return .imagePNG(image) }
        return texte.map { .texte($0) }
    }

    private static func imagePNG(_ pb: NSPasteboard) -> [UInt8]? {
        if let png = pb.data(forType: .png) { return [UInt8](png) }
        // TIFF, JPEG, HEIC (Photos, Aperçu, navigateurs) : converti en PNG.
        guard NSImage.canInit(with: pb), let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return [UInt8](png)
    }

    public func ecrire(_ contenu: ContenuPressePapiers, fini: @escaping @Sendable (Int?) -> Void) {
        file.async { [self] in
            var urls: [URL] = []
            if case .fichiers(let lot) = contenu {
                do { urls = try EcrivainFichiers.poser(lot, dans: dossierRecus) } catch {
                    tracesPP.error("Fichiers reçus impossibles à poser : \(String(describing: error), privacy: .public)")
                    return fini(nil)
                }
            }
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                switch contenu {
                case .texte(let t): pb.setString(t, forType: .string)
                case .imagePNG(let o): pb.setData(Data(o), forType: .png)
                case .fichiers: pb.writeObjects(urls as [NSURL])
                }
                fini(pb.changeCount)
            }
        }
    }
}

/// Met à plat les fichiers copiés, sans suivre les liens symboliques (une app garde les siens tels quels).
enum LecteurFichiers {
    static func lot(_ urls: [URL]) -> LotFichiers? {
        let fm = FileManager.default
        var elements: [LotFichiers.Element] = []
        var racines: Set<String> = []
        var taille = 0
        // Premier passage sans rien lire : on renonce tout de suite si c'est trop gros.
        var aLire: [(Int, String)] = []
        for url in urls {
            let nom = url.lastPathComponent
            guard racines.insert(nom).inserted else { continue }   // deux éléments du même nom : le premier suffit
            var chemins = [(url.path, nom)]
            if let enumerateur = fm.enumerator(atPath: url.path) {
                while let relatif = enumerateur.nextObject() as? String { chemins.append((url.path + "/" + relatif, nom + "/" + relatif)) }
            }
            for (absolu, relatif) in chemins {
                guard let attributs = try? fm.attributesOfItem(atPath: absolu), let type = attributs[.type] as? FileAttributeType else { continue }
                let mode = UInt16((attributs[.posixPermissions] as? Int ?? 0o644) & 0o777)
                switch type {
                case .typeDirectory:
                    elements.append(.init(chemin: relatif, nature: .dossier, mode: mode))
                case .typeRegular:
                    taille += (attributs[.size] as? Int) ?? 0
                    aLire.append((elements.count, absolu))
                    elements.append(.init(chemin: relatif, nature: .fichier, mode: mode))
                case .typeSymbolicLink:
                    guard let cible = try? fm.destinationOfSymbolicLink(atPath: absolu) else { continue }
                    elements.append(.init(chemin: relatif, nature: .lien, mode: mode, contenu: Array(cible.utf8)))
                default:
                    continue   // tubes, sockets : rien à copier
                }
                guard taille <= FormatPressePapiers.fichiers.tailleMax, elements.count <= LotFichiers.maxElements else {
                    tracesPP.info("Copie trop grosse pour le presse-papiers partagé, ignorée")
                    return nil
                }
            }
        }
        for (i, chemin) in aLire {
            guard let donnees = fm.contents(atPath: chemin) else { return nil }
            elements[i].contenu = [UInt8](donnees)
        }
        return elements.isEmpty ? nil : LotFichiers(elements: elements)
    }
}

/// Pose un lot reçu dans un dossier neuf. Le lot a été validé au décodage (chemins relatifs, parents déclarés comme
/// dossiers) : rien ne peut sortir du dossier ni passer à travers un lien.
enum EcrivainFichiers {
    static func poser(_ lot: LotFichiers, dans racine: URL) throws -> [URL] {
        let fm = FileManager.default
        try? fm.removeItem(at: racine)   // l'envoi précédent a déjà été collé (ou ne le sera plus)
        let base = racine.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var dossiers: [(String, UInt16)] = []
        for el in lot.elements {
            let chemin = base.path + "/" + el.chemin
            switch el.nature {
            case .dossier:
                try fm.createDirectory(atPath: chemin, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
                dossiers.append((chemin, el.mode))
            case .fichier:
                guard fm.createFile(atPath: chemin, contents: Data(el.contenu), attributes: [.posixPermissions: Int(el.mode)]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            case .lien:
                try fm.createSymbolicLink(atPath: chemin, withDestinationPath: String(decoding: el.contenu, as: UTF8.self))
            }
        }
        // Droits des dossiers à la fin, des plus profonds aux racines (un dossier en lecture seule bloquerait la suite).
        for (chemin, mode) in dossiers.reversed() { try? fm.setAttributes([.posixPermissions: Int(mode)], ofItemAtPath: chemin) }
        return lot.racines.map { base.appendingPathComponent($0) }
    }
}
#endif
