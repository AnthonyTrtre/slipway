/// Presse-papiers partagé (texte, image, fichiers), sans écho et sans scrutation du contenu :
/// - on ne lit le contenu que si le compteur de changements local (`changeCount`) a bougé ;
/// - ce qu'on vient d'écrire nous-mêmes (reçu d'un pair) n'est jamais renvoyé ;
/// - un contenu déjà envoyé (même empreinte) n'est pas renvoyé.
public struct SynchroPressePapiers: Equatable, Sendable {
    private var dernierCompteurVu: Int?
    private var compteurEcritParNous: Int?
    private var derniereEmpreinte: UInt64?
    private var prochainId: UInt32 = 1

    public init() {}

    /// Le compteur local a peut-être changé. Rend vrai s'il faut lire le texte et appeler `preparerEnvoi`.
    /// La toute première observation sert de référence : on ne pousse pas le presse-papiers déjà présent au lancement.
    public mutating func compteurLocal(_ compteur: Int) -> Bool {
        defer { dernierCompteurVu = compteur }
        guard let precedent = dernierCompteurVu else { return false }
        return compteur != precedent && compteur != compteurEcritParNous
    }

    /// Prépare l'envoi de ce contenu, ou rien s'il est déjà connu, vide ou trop gros.
    public mutating func preparerEnvoi(_ contenu: ContenuPressePapiers) -> EnvoiPressePapiers? {
        let octets = contenu.octets
        guard !octets.isEmpty, octets.count <= contenu.format.tailleMax else { return nil }
        let empreinte = Empreinte.fnv1a(octets)
        guard empreinte != derniereEmpreinte else { return nil }
        derniereEmpreinte = empreinte
        let id = prochainId
        prochainId &+= 1
        return EnvoiPressePapiers(offre: OffrePressePapiers(idTransfert: id, format: contenu.format, taille: UInt32(octets.count), empreinte: empreinte),
                                  octets: octets)
    }

    /// Un contenu reçu va être écrit : on retient son empreinte pour ne pas le renvoyer.
    public mutating func texteRecu(empreinte: UInt64) -> Bool {
        guard empreinte != derniereEmpreinte else { return false }
        derniereEmpreinte = empreinte
        return true
    }

    /// Après écriture dans le presse-papiers local, noter le nouveau compteur (pour ignorer ce changement).
    public mutating func ecritParNous(compteur: Int) {
        compteurEcritParNous = compteur
        dernierCompteurVu = compteur
    }
}

/// Réassemblage d'un transfert de presse-papiers découpé en morceaux (canal fiable et ordonné).
public struct AssembleurPressePapiers: Equatable, Sendable {
    private var offre: OffrePressePapiers?
    private var octets: [UInt8] = []

    public init() {}

    public enum Resultat: Equatable, Sendable {
        case enCours
        case termine(ContenuPressePapiers, empreinte: UInt64)
        case rejete(String)
    }

    public mutating func recevoir(_ m: Message) -> Resultat {
        switch m {
        case .pressePapiersOffre(let o):
            guard Int(o.taille) <= o.format.tailleMax else { offre = nil; return .rejete("trop gros (\(o.taille) octets)") }
            offre = o
            octets = []
            octets.reserveCapacity(Int(o.taille))
            return .enCours
        case .pressePapiersMorceau(let morceau):
            guard let o = offre, morceau.idTransfert == o.idTransfert else { return .rejete("morceau orphelin") }
            guard Int(morceau.decalage) == octets.count, octets.count + morceau.octets.count <= Int(o.taille) else {
                offre = nil
                return .rejete("morceau incohérent")
            }
            octets += morceau.octets
            guard octets.count == Int(o.taille) else { return .enCours }
            offre = nil
            guard Empreinte.fnv1a(octets) == o.empreinte else { return .rejete("empreinte différente") }
            switch o.format {
            case .texteUTF8:
                guard let texte = String(validating: octets, as: UTF8.self) else { return .rejete("UTF-8 invalide") }
                return .termine(.texte(texte), empreinte: o.empreinte)
            case .imagePNG:
                guard octets.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return .rejete("image qui n'est pas un PNG") }
                return .termine(.imagePNG(octets), empreinte: o.empreinte)
            case .fichiers:
                do { return .termine(.fichiers(try LotFichiers.decoder(octets)), empreinte: o.empreinte) } catch {
                    return .rejete("fichiers refusés (\(error))")
                }
            }
        default:
            return .enCours
        }
    }
}

/// Contenu du presse-papiers échangé entre Mac.
public enum ContenuPressePapiers: Equatable, Sendable {
    case texte(String)
    case imagePNG([UInt8])
    case fichiers(LotFichiers)

    public var format: FormatPressePapiers {
        switch self {
        case .texte: .texteUTF8
        case .imagePNG: .imagePNG
        case .fichiers: .fichiers
        }
    }

    public var octets: [UInt8] {
        switch self {
        case .texte(let t): Array(t.utf8)
        case .imagePNG(let o): o
        case .fichiers(let lot): lot.encoder()
        }
    }

    /// Pour le journal : « texte (12 octets) », « image (2,1 Mo) », « 3 fichiers (40 Mo) ».
    public var resume: String {
        switch self {
        case .texte(let t): "texte (\(t.utf8.count) octets)"
        case .imagePNG(let o): "image (\(Self.taille(o.count)))"
        case .fichiers(let lot): "\(lot.racines.count) élément\(lot.racines.count > 1 ? "s" : "") du Finder (\(Self.taille(lot.taille)))"
        }
    }

    static func taille(_ n: Int) -> String {
        n < 1024 * 1024 ? "\(max(1, n / 1024)) ko" : "\(n / (1024 * 1024)) Mo"
    }
}

extension FormatPressePapiers {
    /// Taille maximale acceptée, à l'envoi comme à la réception.
    public var tailleMax: Int {
        switch self {
        case .texteUTF8: 4 * 1024 * 1024
        case .imagePNG: 64 * 1024 * 1024
        case .fichiers: 256 * 1024 * 1024
        }
    }
}

/// Envoi en cours vers un pair : l'offre, puis les morceaux au fil de l'eau (un gros fichier ne doit pas
/// retarder les touches et les clics qui partent sur le même canal).
public struct EnvoiPressePapiers: Equatable, Sendable {
    public let offre: OffrePressePapiers
    public let octets: [UInt8]
    public private(set) var decalage = 0
    public init(offre: OffrePressePapiers, octets: [UInt8]) { self.offre = offre; self.octets = octets }

    public var fini: Bool { decalage >= octets.count }

    /// Morceaux suivants, `budget` octets au plus (au moins un morceau).
    public mutating func morceaux(budget: Int) -> [Message] {
        var messages: [Message] = []
        var envoye = 0
        while !fini, messages.isEmpty || envoye + Protocole.tailleMorceauPressePapiers <= budget {
            let fin = min(decalage + Protocole.tailleMorceauPressePapiers, octets.count)
            messages.append(.pressePapiersMorceau(MorceauPressePapiers(idTransfert: offre.idTransfert, decalage: UInt32(decalage),
                                                                       octets: Array(octets[decalage..<fin]))))
            envoye += fin - decalage
            decalage = fin
        }
        return messages
    }
}
