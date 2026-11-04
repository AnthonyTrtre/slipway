/// Géométrie de Slipway. Tout est en **points** (jamais en pixels) :
/// - espace local d'un Mac = espace global Quartz (origine en haut à gauche de l'écran principal, y vers le bas) ;
/// - bureau virtuel = espace commun où l'utilisateur place les Mac les uns par rapport aux autres.
/// Un point local devient virtuel en ajoutant le décalage du Mac dans la disposition.

public struct Point: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Point(x: 0, y: 0)
    public static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
    public func distance(a autre: Point) -> Double { ((x - autre.x) * (x - autre.x) + (y - autre.y) * (y - autre.y)).squareRoot() }
}

public struct Rect: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var largeur: Double
    public var hauteur: Double
    public init(x: Double, y: Double, largeur: Double, hauteur: Double) {
        self.x = x; self.y = y; self.largeur = largeur; self.hauteur = hauteur
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + largeur }
    public var maxY: Double { y + hauteur }
    public var centre: Point { Point(x: x + largeur / 2, y: y + hauteur / 2) }

    /// Intervalle semi-ouvert [min, max) : un point du bord droit appartient à l'écran voisin.
    public func contient(_ p: Point) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }

    /// Le point le plus proche à l'intérieur du rectangle.
    public func borner(_ p: Point) -> Point {
        let epsilon = 0.001
        return Point(x: min(max(p.x, minX), maxX - epsilon), y: min(max(p.y, minY), maxY - epsilon))
    }

    public func decale(de d: Point) -> Rect { Rect(x: x + d.x, y: y + d.y, largeur: largeur, hauteur: hauteur) }

    /// Intersection d'aire non nulle (des rectangles qui se touchent seulement ne se chevauchent pas).
    public func chevauche(_ r: Rect) -> Bool { minX < r.maxX && r.minX < maxX && minY < r.maxY && r.minY < maxY }

    public func union(_ r: Rect) -> Rect {
        let x0 = min(minX, r.minX), y0 = min(minY, r.minY)
        return Rect(x: x0, y: y0, largeur: max(maxX, r.maxX) - x0, hauteur: max(maxY, r.maxY) - y0)
    }
}

/// Un écran physique d'un Mac, en points dans l'espace local de ce Mac.
public struct Ecran: Equatable, Hashable, Sendable, Codable {
    public var id: UInt32
    public var cadre: Rect
    public var echelle: Double
    public var principal: Bool
    public init(id: UInt32, cadre: Rect, echelle: Double = 2, principal: Bool = false) {
        self.id = id; self.cadre = cadre; self.echelle = echelle; self.principal = principal
    }

    public init(_ d: EcranDecrit) {
        self.init(id: d.id, cadre: Rect(x: Double(d.x), y: Double(d.y), largeur: Double(d.largeur), hauteur: Double(d.hauteur)),
                  echelle: Double(d.echelle), principal: d.principal)
    }

    public var decrit: EcranDecrit {
        EcranDecrit(id: id, x: Float(cadre.x), y: Float(cadre.y), largeur: Float(cadre.largeur), hauteur: Float(cadre.hauteur),
                    echelle: Float(echelle), principal: principal)
    }
}

/// Identifiant stable d'un Mac : 16 caractères hexadécimaux tirés de sa clé publique d'identité.
public struct IdPair: RawRepresentable, Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(cleIdentite: [UInt8]) { rawValue = Hex.encoder(Array(cleIdentite.prefix(8))) }
    /// Les 8 octets de l'identifiant (forme binaire du protocole).
    public var octets: [UInt8] { Hex.decoder(rawValue) ?? [] }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
}
