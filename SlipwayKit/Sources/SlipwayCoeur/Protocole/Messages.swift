/// Messages du protocole Slipway v1. La spécification qui fait foi est `apps/slipway/docs/protocole.md` ;
/// ce fichier en est l'implémentation de référence, vérifiée par les octets de référence (`docs/octets-de-reference/`).

public enum Protocole {
    public static let versionMajeure: UInt8 = 1
    public static let versionMineure: UInt8 = 0
    /// « SLPW » en ASCII.
    public static let magie: [UInt8] = [0x53, 0x4C, 0x50, 0x57]
    public static let tailleEntete = 8
    /// Taille maximale d'une trame (en-tête compris) : la longueur de charge tient sur 16 bits.
    public static let tailleMaxTrame = tailleEntete + Int(UInt16.max)
    /// Type de service Bonjour publié par chaque Mac.
    public static let serviceBonjour = "_slipway._tcp"
    /// Taille des morceaux de presse-papiers (laisse de la marge sous la limite de trame, scellement compris).
    public static let tailleMorceauPressePapiers = 32 * 1024
}

/// Capacités annoncées dans la poignée de main (champ de bits). Une mineure plus récente ajoute des bits ;
/// on n'utilise que l'intersection des deux côtés.
public struct Capacites: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let pointeur = Capacites(rawValue: 1 << 0)
    public static let clavier = Capacites(rawValue: 1 << 1)
    public static let pressePapiersTexte = Capacites(rawValue: 1 << 2)
    public static let toutes: Capacites = [.pointeur, .clavier, .pressePapiersTexte]
}

public enum TypeMessage: UInt8, Sendable, CaseIterable {
    // Poignée de main, en clair, canal fiable.
    case bonjourClient = 0x01
    case bonjourServeur = 0x02
    case revelation = 0x03
    // Canal fiable, scellé.
    case preuve = 0x04
    case confirmationAppairage = 0x05
    case auRevoir = 0x06
    case ecrans = 0x07
    case disposition = 0x08
    case role = 0x09
    case entree = 0x10
    case sortie = 0x11
    case bouton = 0x12
    case touche = 0x13
    case toucheSysteme = 0x14
    case toutRelacher = 0x15
    case pressePapiersOffre = 0x20
    case pressePapiersMorceau = 0x21
    // Les deux canaux (battement de cœur et mesure de latence).
    case ping = 0x30
    case pong = 0x31
    // Canal temps réel (datagrammes), scellé.
    case mouvement = 0x40
    case defilement = 0x41
}

public struct BonjourClient: Equatable, Sendable {
    public var versionMajeure: UInt8 = Protocole.versionMajeure
    public var versionMineure: UInt8 = Protocole.versionMineure
    public var capacites: Capacites
    /// Clé publique d'identité Ed25519 (32 octets).
    public var cleIdentite: [UInt8]
    /// Engagement SHA-256(cléÉphémère ‖ aléa) : empêche un intermédiaire de choisir sa clé après avoir vu l'autre.
    public var engagement: [UInt8]
    public var nom: String

    public init(capacites: Capacites, cleIdentite: [UInt8], engagement: [UInt8], nom: String,
                versionMajeure: UInt8 = Protocole.versionMajeure, versionMineure: UInt8 = Protocole.versionMineure) {
        self.capacites = capacites; self.cleIdentite = cleIdentite; self.engagement = engagement; self.nom = nom
        self.versionMajeure = versionMajeure; self.versionMineure = versionMineure
    }
}

public struct BonjourServeur: Equatable, Sendable {
    public var versionMajeure: UInt8 = Protocole.versionMajeure
    public var versionMineure: UInt8 = Protocole.versionMineure
    public var capacites: Capacites
    public var cleIdentite: [UInt8]
    /// Clé publique éphémère X25519 (32 octets).
    public var cleEphemere: [UInt8]
    /// Aléa de 16 octets.
    public var alea: [UInt8]
    /// Port UDP du canal temps réel de ce Mac.
    public var portUDP: UInt16
    public var nom: String

    public init(capacites: Capacites, cleIdentite: [UInt8], cleEphemere: [UInt8], alea: [UInt8], portUDP: UInt16, nom: String,
                versionMajeure: UInt8 = Protocole.versionMajeure, versionMineure: UInt8 = Protocole.versionMineure) {
        self.capacites = capacites; self.cleIdentite = cleIdentite; self.cleEphemere = cleEphemere; self.alea = alea
        self.portUDP = portUDP; self.nom = nom; self.versionMajeure = versionMajeure; self.versionMineure = versionMineure
    }
}

public struct Revelation: Equatable, Sendable {
    public var cleEphemere: [UInt8]
    public var alea: [UInt8]
    public init(cleEphemere: [UInt8], alea: [UInt8]) { self.cleEphemere = cleEphemere; self.alea = alea }
}

public enum RaisonDepart: UInt8, Sendable {
    case normal = 0
    case versionIncompatible = 1
    case appairageRefuse = 2
    case authentificationEchouee = 3
    case occupe = 4
    case erreurProtocole = 5
}

public enum RaisonSortie: UInt8, Sendable {
    case bascule = 0
    case panique = 1
    case veille = 2
    case arret = 3
    case delai = 4
}

/// Un écran tel que son Mac le décrit : en points, dans l'espace global de ce Mac
/// (origine en haut à gauche de l'écran principal, y vers le bas).
public struct EcranDecrit: Equatable, Sendable {
    public var id: UInt32
    public var x: Float
    public var y: Float
    public var largeur: Float
    public var hauteur: Float
    /// Facteur d'échelle (2 pour un écran Retina).
    public var echelle: Float
    public var principal: Bool

    public init(id: UInt32, x: Float, y: Float, largeur: Float, hauteur: Float, echelle: Float, principal: Bool) {
        self.id = id; self.x = x; self.y = y; self.largeur = largeur; self.hauteur = hauteur
        self.echelle = echelle; self.principal = principal
    }
}

/// Position d'un Mac dans le bureau virtuel partagé (décalage local → virtuel, en points).
public struct PlaceDecrite: Equatable, Sendable {
    /// Identifiant du Mac : 8 octets (les 8 premiers de sa clé publique d'identité).
    public var id: [UInt8]
    public var x: Float
    public var y: Float
    public init(id: [UInt8], x: Float, y: Float) { self.id = id; self.x = x; self.y = y }
}

public struct Entree: Equatable, Sendable {
    /// Point d'entrée dans l'espace global du Mac qui reçoit.
    public var x: Float
    public var y: Float
    public var modificateurs: Modificateurs
    public init(x: Float, y: Float, modificateurs: Modificateurs) { self.x = x; self.y = y; self.modificateurs = modificateurs }
}

/// Numéro de bouton : 0 gauche, 1 droit, 2 milieu, 3 et 4 boutons latéraux, jusqu'à 31.
public struct BoutonSouris: RawRepresentable, Hashable, Sendable, Comparable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let gauche = BoutonSouris(rawValue: 0)
    public static let droit = BoutonSouris(rawValue: 1)
    public static let milieu = BoutonSouris(rawValue: 2)
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct EvenementBouton: Equatable, Sendable {
    public var bouton: BoutonSouris
    public var enfonce: Bool
    /// Compteur de clics calculé par le Mac qui capture (1 simple, 2 double, 3 triple).
    public var nbClics: UInt8
    /// Position à laquelle appliquer le clic (espace du Mac qui reçoit).
    public var x: Float
    public var y: Float
    public init(bouton: BoutonSouris, enfonce: Bool, nbClics: UInt8, x: Float, y: Float) {
        self.bouton = bouton; self.enfonce = enfonce; self.nbClics = nbClics; self.x = x; self.y = y
    }
}

public struct EvenementTouche: Equatable, Sendable {
    /// Usage HID (page 0x07) ou code étendu Slipway (voir `CodeTouche`).
    public var usage: UInt16
    public var enfonce: Bool
    public var repetition: Bool
    /// État complet des modificateurs après l'événement.
    public var modificateurs: Modificateurs
    public init(usage: UInt16, enfonce: Bool, repetition: Bool, modificateurs: Modificateurs) {
        self.usage = usage; self.enfonce = enfonce; self.repetition = repetition; self.modificateurs = modificateurs
    }
}

public struct ToucheSysteme: Equatable, Sendable {
    /// Usage HID de la page consommateur (0x0C) : volume, lecture, luminosité…
    public var usage: UInt16
    public var enfonce: Bool
    public var repetition: Bool
    public init(usage: UInt16, enfonce: Bool, repetition: Bool) { self.usage = usage; self.enfonce = enfonce; self.repetition = repetition }
}

public enum FormatPressePapiers: UInt8, Sendable {
    case texteUTF8 = 1
}

public struct OffrePressePapiers: Equatable, Sendable {
    public var idTransfert: UInt32
    public var format: FormatPressePapiers
    public var taille: UInt32
    /// Empreinte FNV-1a 64 bits du contenu : déduplication et anti-écho (pas un contrôle de sécurité).
    public var empreinte: UInt64
    public init(idTransfert: UInt32, format: FormatPressePapiers, taille: UInt32, empreinte: UInt64) {
        self.idTransfert = idTransfert; self.format = format; self.taille = taille; self.empreinte = empreinte
    }
}

public struct MorceauPressePapiers: Equatable, Sendable {
    public var idTransfert: UInt32
    public var decalage: UInt32
    public var octets: [UInt8]
    public init(idTransfert: UInt32, decalage: UInt32, octets: [UInt8]) { self.idTransfert = idTransfert; self.decalage = decalage; self.octets = octets }
}

/// Phase de défilement neutre (indépendante de macOS).
public enum PhaseDefilement: UInt8, Sendable {
    case aucune = 0, debut = 1, changement = 2, fin = 3, annule = 4, peutCommencer = 5
}

/// Phase d'inertie (momentum) neutre.
public enum PhaseInertie: UInt8, Sendable {
    case aucune = 0, debut = 1, enCours = 2, fin = 3
}

public struct Mouvement: Equatable, Sendable {
    /// Déplacement brut capturé, en points, précision complète (déjà accéléré par le Mac qui capture).
    public var dx: Float
    public var dy: Float
    /// Position absolue visée chez le Mac qui reçoit : il la poste telle quelle (bornée à ses écrans).
    public var x: Float
    public var y: Float
    /// Boutons enfoncés (bit n = bouton n) : le récepteur poste un « glisser » si non nul.
    public var boutons: UInt8
    public init(dx: Float, dy: Float, x: Float, y: Float, boutons: UInt8) { self.dx = dx; self.dy = dy; self.x = x; self.y = y; self.boutons = boutons }
}

public struct Defilement: Equatable, Sendable {
    public var dxPoints: Float
    public var dyPoints: Float
    public var dxLignes: Float
    public var dyLignes: Float
    public var phase: PhaseDefilement
    public var inertie: PhaseInertie
    /// Vrai pour un pavé tactile ou une Magic Mouse (défilement en pixels), faux pour une molette à crans.
    public var continu: Bool
    public init(dxPoints: Float, dyPoints: Float, dxLignes: Float, dyLignes: Float, phase: PhaseDefilement, inertie: PhaseInertie, continu: Bool) {
        self.dxPoints = dxPoints; self.dyPoints = dyPoints; self.dxLignes = dxLignes; self.dyLignes = dyLignes
        self.phase = phase; self.inertie = inertie; self.continu = continu
    }
}

public enum Message: Equatable, Sendable {
    case bonjourClient(BonjourClient)
    case bonjourServeur(BonjourServeur)
    case revelation(Revelation)
    case preuve(signature: [UInt8])
    case confirmationAppairage
    case auRevoir(raison: RaisonDepart, texte: String)
    case ecrans([EcranDecrit])
    /// Disposition partagée : la révision la plus grande l'emporte (0 = placement automatique, jamais envoyé).
    case disposition(revision: UInt64, places: [PlaceDecrite])
    /// Rôle choisi à la main sur l'expéditeur (principal ou secondaire) : l'autre Mac prend le rôle inverse.
    case role(principal: Bool)
    case entree(Entree)
    case sortie(RaisonSortie)
    case bouton(EvenementBouton)
    case touche(EvenementTouche)
    case toucheSysteme(ToucheSysteme)
    case toutRelacher
    case pressePapiersOffre(OffrePressePapiers)
    case pressePapiersMorceau(MorceauPressePapiers)
    case ping(horodatage: UInt64)
    case pong(horodatage: UInt64)
    case mouvement(Mouvement)
    case defilement(Defilement)
    /// Type inconnu (version mineure plus récente) : ignoré sans erreur.
    case inconnu(type: UInt8, charge: [UInt8])

    public var type: UInt8 {
        switch self {
        case .bonjourClient: TypeMessage.bonjourClient.rawValue
        case .bonjourServeur: TypeMessage.bonjourServeur.rawValue
        case .revelation: TypeMessage.revelation.rawValue
        case .preuve: TypeMessage.preuve.rawValue
        case .confirmationAppairage: TypeMessage.confirmationAppairage.rawValue
        case .auRevoir: TypeMessage.auRevoir.rawValue
        case .ecrans: TypeMessage.ecrans.rawValue
        case .disposition: TypeMessage.disposition.rawValue
        case .role: TypeMessage.role.rawValue
        case .entree: TypeMessage.entree.rawValue
        case .sortie: TypeMessage.sortie.rawValue
        case .bouton: TypeMessage.bouton.rawValue
        case .touche: TypeMessage.touche.rawValue
        case .toucheSysteme: TypeMessage.toucheSysteme.rawValue
        case .toutRelacher: TypeMessage.toutRelacher.rawValue
        case .pressePapiersOffre: TypeMessage.pressePapiersOffre.rawValue
        case .pressePapiersMorceau: TypeMessage.pressePapiersMorceau.rawValue
        case .ping: TypeMessage.ping.rawValue
        case .pong: TypeMessage.pong.rawValue
        case .mouvement: TypeMessage.mouvement.rawValue
        case .defilement: TypeMessage.defilement.rawValue
        case .inconnu(let type, _): type
        }
    }

    /// Vrai pour les messages qui voyagent sur le canal temps réel (datagrammes).
    public var estTempsReel: Bool {
        switch self {
        case .mouvement, .defilement: true
        default: false
        }
    }
}

/// Une trame = en-tête de 8 octets + charge.
public struct Trame: Equatable, Sendable {
    public var sequence: UInt32
    public var drapeaux: UInt8
    public var message: Message
    public init(sequence: UInt32, message: Message, drapeaux: UInt8 = 0) {
        self.sequence = sequence; self.message = message; self.drapeaux = drapeaux
    }
}
