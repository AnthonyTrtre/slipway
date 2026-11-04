
/// Place d'un Mac dans le bureau virtuel.
public struct PlaceMac: Equatable, Sendable, Codable {
    public var nom: String
    public var ecrans: [Ecran]
    /// Décalage local → virtuel.
    public var decalage: Point
    /// Multiplicateur appliqué aux déplacements quand on pilote ce Mac (écrans de densités différentes).
    public var facteurVitesse: Double

    public init(nom: String, ecrans: [Ecran], decalage: Point = .zero, facteurVitesse: Double = 1) {
        self.nom = nom; self.ecrans = ecrans; self.decalage = decalage; self.facteurVitesse = facteurVitesse
    }

    public func versVirtuel(_ p: Point) -> Point { p + decalage }
    public func versLocal(_ v: Point) -> Point { v - decalage }
    public var cadresVirtuels: [Rect] { ecrans.map { $0.cadre.decale(de: decalage) } }

    /// Rectangle englobant de tous les écrans, en coordonnées virtuelles.
    public var englobantVirtuel: Rect? {
        guard var r = cadresVirtuels.first else { return nil }
        for c in cadresVirtuels.dropFirst() { r = r.union(c) }
        return r
    }

    public func contientLocal(_ p: Point) -> Bool { ecrans.contains { $0.cadre.contient(p) } }

    /// Le point le plus proche à l'intérieur d'un des écrans (gère les trous entre écrans de tailles différentes).
    public func bornerLocal(_ p: Point) -> Point {
        if contientLocal(p) { return p }
        var meilleur = p
        var distance = Double.infinity
        for e in ecrans {
            let candidat = e.cadre.borner(p)
            let d = candidat.distance(a: p)
            if d < distance { distance = d; meilleur = candidat }
        }
        return meilleur
    }
}

public struct ReglagesBords: Equatable, Sendable, Codable {
    /// Taille (points) des coins où le passage est désactivé (coins actifs, menu Pomme, Dock…). 0 = aucun.
    public var tailleCoinsMorts: Double
    /// Durée pendant laquelle il faut pousser contre le bord avant de basculer (secondes). 0 = immédiat.
    public var delaiBord: Double

    public init(tailleCoinsMorts: Double = 0, delaiBord: Double = 0) {
        self.tailleCoinsMorts = tailleCoinsMorts; self.delaiBord = delaiBord
    }
}

public enum ResultatDeplacement: Equatable, Sendable {
    /// Le curseur reste sur le même Mac, à cette position locale (bornée à ses écrans).
    case reste(Point)
    /// Le curseur passe sur `mac`, au point `entree` (local au Mac cible) ; `sortie` = dernier point local au Mac quitté.
    case bascule(vers: IdPair, entree: Point, sortie: Point)
}

/// Disposition de tous les Mac dans le bureau virtuel. Valeur pure : copiable, comparable, sérialisable en JSON.
public struct Disposition: Equatable, Sendable, Codable {
    public var macs: [IdPair: PlaceMac]
    public var reglages: ReglagesBords
    /// 0 = placement automatique ; sinon horodatage (ms) de la dernière modification faite par l'utilisateur sur un des Mac.
    /// La révision la plus grande l'emporte quand deux Mac échangent leur disposition.
    public var revision: UInt64

    public init(macs: [IdPair: PlaceMac] = [:], reglages: ReglagesBords = ReglagesBords(), revision: UInt64 = 0) {
        self.macs = macs; self.reglages = reglages; self.revision = revision
    }

    /// Les places à partager (message `Disposition`).
    public var placesDecrites: [PlaceDecrite] {
        macs.sorted { $0.key < $1.key }.map { PlaceDecrite(id: $0.key.octets, x: Float($0.value.decalage.x), y: Float($0.value.decalage.y)) }
    }

    /// Applique une disposition reçue si elle est plus récente. Rend vrai si quelque chose a changé.
    public mutating func appliquer(revision r: UInt64, places: [PlaceDecrite]) -> Bool {
        // Un saut aberrant (révision proche du maximum) bloquerait toute modification future : refusé.
        guard r > revision, r - revision <= 1_000_000 else { return false }
        revision = r
        for p in places {
            let id = IdPair(cleIdentite: p.id)
            var place = macs[id] ?? PlaceMac(nom: "", ecrans: [])
            place.decalage = Point(x: Double(p.x), y: Double(p.y))
            macs[id] = place
        }
        return true
    }

    /// Calcule le déplacement du curseur de `depuis` (local au Mac `mac`) par le vecteur `delta`.
    ///
    /// Règle de sortie : on sort quand le point visé, ou le point situé un point plus loin dans le sens du
    /// mouvement, n'est plus sur un écran du Mac. Ainsi une poussée lente contre le bord (où macOS bloque le
    /// curseur) finit bien par basculer, et la couture entre deux écrans d'un même Mac n'est pas une sortie.
    public func deplacer(depuis p: Point, de delta: Point, sur mac: IdPair) -> ResultatDeplacement {
        guard let place = macs[mac], !place.ecrans.isEmpty else { return .reste(p) }
        let cible = p + delta
        let pas = Point(x: Self.signe(delta.x), y: Self.signe(delta.y))
        let sort = !place.contientLocal(cible) || ((pas.x != 0 || pas.y != 0) && !place.contientLocal(cible + pas))
        guard sort else { return .reste(cible) }

        let sortie = place.bornerLocal(cible)
        if !estDansUnCoinMort(sortie, place: place) {
            // Le point visé, ou à défaut le point juste de l'autre côté du bord, doit tomber sur un écran d'un autre Mac.
            let vise = place.versVirtuel(cible)
            let auDela = place.versVirtuel(cible + pas)
            for (id, autre) in macs.sorted(by: { $0.key < $1.key }) where id != mac {
                for cadre in autre.ecrans.map(\.cadre) {
                    let cadreVirtuel = cadre.decale(de: autre.decalage)
                    if cadreVirtuel.contient(vise) || cadreVirtuel.contient(auDela) {
                        // Entrée au point visé (mouvement continu, en miroir du point de sortie), ramené sur l'écran.
                        let entree = cadre.borner(autre.versLocal(vise))
                        return .bascule(vers: id, entree: entree, sortie: sortie)
                    }
                }
            }
        }
        return .reste(sortie)
    }

    func estDansUnCoinMort(_ p: Point, place: PlaceMac) -> Bool {
        let t = reglages.tailleCoinsMorts
        guard t > 0 else { return false }
        guard let ecran = place.ecrans.first(where: { $0.cadre.contient(p) }) ?? place.ecrans.first else { return false }
        let c = ecran.cadre
        let presDuBordX = p.x - c.minX < t || c.maxX - p.x <= t
        let presDuBordY = p.y - c.minY < t || c.maxY - p.y <= t
        return presDuBordX && presDuBordY
    }

    private static func signe(_ v: Double) -> Double { v > 0 ? 1 : (v < 0 ? -1 : 0) }

    // MARK: - Édition de la disposition

    /// Vrai si au moins un écran de `mac` touche (bord commun de longueur non nulle) un écran d'un autre Mac.
    public func estAccessible(_ mac: IdPair) -> Bool {
        guard let place = macs[mac] else { return false }
        for (id, autre) in macs where id != mac {
            for a in place.cadresVirtuels {
                for b in autre.cadresVirtuels where Self.bordCommun(a, b) > 0 { return true }
            }
        }
        return false
    }

    /// Longueur du bord partagé par deux rectangles qui se touchent (0 sinon).
    public static func bordCommun(_ a: Rect, _ b: Rect, tolerance: Double = 0.5) -> Double {
        let recouvrementX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let recouvrementY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        if abs(a.maxX - b.minX) <= tolerance || abs(b.maxX - a.minX) <= tolerance { return max(0, recouvrementY) }
        if abs(a.maxY - b.minY) <= tolerance || abs(b.maxY - a.minY) <= tolerance { return max(0, recouvrementX) }
        return 0
    }

    /// Décalage final quand l'utilisateur lâche le Mac `mac` à `decalagePropose` dans l'éditeur :
    /// 1. aimantation des bords et des alignements à moins de `seuil` points ;
    /// 2. aucun chevauchement : on repousse le Mac hors des autres par le plus petit déplacement.
    public func aimanter(_ mac: IdPair, decalagePropose: Point, seuil: Double = 40) -> Point {
        guard let place = macs[mac] else { return decalagePropose }
        var d = decalagePropose
        let autres = macs.filter { $0.key != mac }.compactMap { $0.value.englobantVirtuel }
        guard var moi = PlaceMac(nom: "", ecrans: place.ecrans, decalage: d).englobantVirtuel else { return d }

        var meilleurX: (Double, Double)? = nil   // (distance, correction)
        var meilleurY: (Double, Double)? = nil
        func proposer(_ ecart: Double, _ meilleur: inout (Double, Double)?) {
            guard abs(ecart) <= seuil else { return }
            if meilleur == nil || abs(ecart) < meilleur!.0 { meilleur = (abs(ecart), ecart) }
        }
        for r in autres {
            for ecart in [r.minX - moi.maxX, r.maxX - moi.minX, r.minX - moi.minX, r.maxX - moi.maxX] { proposer(ecart, &meilleurX) }
            for ecart in [r.minY - moi.maxY, r.maxY - moi.minY, r.minY - moi.minY, r.maxY - moi.maxY] { proposer(ecart, &meilleurY) }
        }
        if let (_, c) = meilleurX { d.x += c }
        if let (_, c) = meilleurY { d.y += c }

        // Résolution des chevauchements (quelques passes suffisent pour 2 à 4 Mac).
        for _ in 0..<8 {
            moi = PlaceMac(nom: "", ecrans: place.ecrans, decalage: d).englobantVirtuel!
            guard let r = autres.first(where: { $0.chevauche(moi) }) else { break }
            let options = [
                Point(x: r.minX - moi.maxX, y: 0), Point(x: r.maxX - moi.minX, y: 0),
                Point(x: 0, y: r.minY - moi.maxY), Point(x: 0, y: r.maxY - moi.minY),
            ]
            let correction = options.min { abs($0.x) + abs($0.y) < abs($1.x) + abs($1.y) }!
            d = d + correction
        }
        return d
    }

    /// Placement automatique d'un nouveau Mac, identique vu de chaque Mac : un identifiant plus petit que tous les
    /// autres va à gauche de l'ensemble, sinon à droite ; centré verticalement sur l'ensemble.
    /// (Deux Mac A < B : A voit B à sa droite, B voit A à sa gauche.)
    public mutating func placerAutomatiquement(_ mac: IdPair) {
        guard var place = macs[mac], let moi = PlaceMac(nom: "", ecrans: place.ecrans).englobantVirtuel else { return }
        let autres = macs.filter { $0.key != mac && $0.value.englobantVirtuel != nil }
        guard var global = autres.first?.value.englobantVirtuel else { return }
        for r in autres.compactMap({ $0.value.englobantVirtuel }) { global = global.union(r) }
        let aGauche = autres.keys.allSatisfy { mac < $0 }
        let x = aGauche ? global.minX - moi.maxX : global.maxX - moi.minX
        place.decalage = Point(x: x, y: global.minY + (global.hauteur - moi.hauteur) / 2 - moi.minY)
        macs[mac] = place
    }
}
