/// Fichiers, dossiers et apps copiés dans le Finder, mis à plat pour le presse-papiers partagé.
///
/// Format : « SLPF » | version u8 | nombre u32 | pour chaque élément : nature u8 | chemin (u16 + UTF-8) |
/// mode u16 | longueur u64 | contenu (octets du fichier, cible du lien, rien pour un dossier).
///
/// Le décodage refuse tout ce qui pourrait écrire hors du dossier de réception : chemin absolu, `..`, composant vide,
/// doublon, ou parent qui n'est pas un dossier déclaré plus tôt dans le lot (on n'écrit donc jamais à travers un lien).
public struct LotFichiers: Equatable, Sendable {
    public enum Nature: UInt8, Sendable { case dossier = 0, fichier = 1, lien = 2 }

    public struct Element: Equatable, Sendable {
        /// Chemin relatif, composants séparés par « / » (le premier composant est un élément copié).
        public var chemin: String
        public var nature: Nature
        /// Droits POSIX (0o777 au plus : jamais de setuid ni de setgid).
        public var mode: UInt16
        /// Octets du fichier, ou cible du lien en UTF-8.
        public var contenu: [UInt8]
        public init(chemin: String, nature: Nature, mode: UInt16 = 0o644, contenu: [UInt8] = []) {
            self.chemin = chemin; self.nature = nature; self.mode = mode & 0o777; self.contenu = contenu
        }
    }

    public enum Erreur: Error, Equatable { case illisible(String) }

    public static let magie: [UInt8] = Array("SLPF".utf8)
    public static let maxElements = 100_000

    public var elements: [Element]
    public init(elements: [Element]) { self.elements = elements }

    /// Éléments copiés (premier niveau), dans l'ordre.
    public var racines: [String] { elements.map(\.chemin).filter { !$0.contains("/") } }
    public var taille: Int { elements.reduce(0) { $0 + $1.contenu.count } }

    public func encoder() -> [UInt8] {
        var e = EcrivainOctets(capacite: taille + elements.count * 64 + 16)
        e.brut(Self.magie)
        e.u8(1)
        e.u32(UInt32(elements.count))
        for el in elements {
            let chemin = Array(el.chemin.utf8)
            e.u8(el.nature.rawValue)
            e.u16(UInt16(chemin.count))
            e.brut(chemin)
            e.u16(el.mode & 0o777)
            e.u64(UInt64(el.contenu.count))
            e.brut(el.contenu)
        }
        return e.octets
    }

    public static func decoder(_ octets: [UInt8]) throws(Erreur) -> LotFichiers {
        var l = LecteurOctets(octets)
        do {
            guard try l.brut(4) == magie, try l.u8() == 1 else { throw Erreur.illisible("en-tête") }
            let n = Int(try l.u32())
            guard n > 0, n <= maxElements else { throw Erreur.illisible("\(n) éléments") }
            var elements: [Element] = []
            elements.reserveCapacity(n)
            var dossiers: Set<String> = []
            var vus: Set<String> = []
            for _ in 0..<n {
                guard let nature = Nature(rawValue: try l.u8()) else { throw Erreur.illisible("nature") }
                let brut = try l.brut(Int(try l.u16()))
                guard let chemin = String(validating: brut, as: UTF8.self), cheminSur(chemin) else { throw Erreur.illisible("chemin") }
                if let i = chemin.lastIndex(of: "/"), !dossiers.contains(String(chemin[..<i])) { throw Erreur.illisible("parent de \(chemin)") }
                guard vus.insert(chemin).inserted else { throw Erreur.illisible("doublon \(chemin)") }
                let mode = try l.u16() & 0o777
                let longueur = try l.u64()
                guard longueur <= UInt64(l.restant) else { throw Erreur.illisible("longueur") }
                let contenu = try l.brut(Int(longueur))
                switch nature {
                case .dossier: guard contenu.isEmpty else { throw Erreur.illisible("dossier non vide") }; dossiers.insert(chemin)
                case .lien: guard !contenu.isEmpty, contenu.count <= 1024, !contenu.contains(0) else { throw Erreur.illisible("lien") }
                case .fichier: break
                }
                elements.append(Element(chemin: chemin, nature: nature, mode: mode, contenu: contenu))
            }
            guard l.restant == 0 else { throw Erreur.illisible("octets en trop") }
            return LotFichiers(elements: elements)
        } catch let e as Erreur {
            throw e
        } catch {
            throw Erreur.illisible("tronqué")
        }
    }

    static func cheminSur(_ chemin: String) -> Bool {
        guard !chemin.isEmpty, chemin.utf8.count <= 1024, !chemin.utf8.contains(0) else { return false }
        return chemin.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }
    }
}
