/// Presse-papiers texte partagé, sans écho et sans scrutation du contenu :
/// - on ne lit le contenu que si le compteur de changements local (`changeCount`) a bougé ;
/// - ce qu'on vient d'écrire nous-mêmes (reçu d'un pair) n'est jamais renvoyé ;
/// - un contenu déjà envoyé (même empreinte) n'est pas renvoyé.
public struct SynchroPressePapiers: Equatable, Sendable {
    public var tailleMax: Int
    private var dernierCompteurVu: Int?
    private var compteurEcritParNous: Int?
    private var derniereEmpreinte: UInt64?
    private var prochainId: UInt32 = 1

    public init(tailleMax: Int = 4 * 1024 * 1024) { self.tailleMax = tailleMax }

    /// Le compteur local a peut-être changé. Rend vrai s'il faut lire le texte et appeler `preparerEnvoi`.
    /// La toute première observation sert de référence : on ne pousse pas le presse-papiers déjà présent au lancement.
    public mutating func compteurLocal(_ compteur: Int) -> Bool {
        defer { dernierCompteurVu = compteur }
        guard let precedent = dernierCompteurVu else { return false }
        return compteur != precedent && compteur != compteurEcritParNous
    }

    /// Prépare l'offre et les morceaux à envoyer pour ce texte, ou rien s'il est déjà connu, vide ou trop gros.
    public mutating func preparerEnvoi(texte: String) -> [Message] {
        let octets = Array(texte.utf8)
        guard !octets.isEmpty, octets.count <= tailleMax else { return [] }
        let empreinte = Empreinte.fnv1a(octets)
        guard empreinte != derniereEmpreinte else { return [] }
        derniereEmpreinte = empreinte
        let id = prochainId
        prochainId &+= 1
        var messages: [Message] = [.pressePapiersOffre(OffrePressePapiers(idTransfert: id, format: .texteUTF8, taille: UInt32(octets.count), empreinte: empreinte))]
        var decalage = 0
        while decalage < octets.count {
            let fin = min(decalage + Protocole.tailleMorceauPressePapiers, octets.count)
            messages.append(.pressePapiersMorceau(MorceauPressePapiers(idTransfert: id, decalage: UInt32(decalage), octets: Array(octets[decalage..<fin]))))
            decalage = fin
        }
        return messages
    }

    /// Un texte reçu va être écrit : on retient son empreinte pour ne pas le renvoyer.
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
    public var tailleMax: Int
    private var offre: OffrePressePapiers?
    private var octets: [UInt8] = []

    public init(tailleMax: Int = 4 * 1024 * 1024) { self.tailleMax = tailleMax }

    public enum Resultat: Equatable, Sendable {
        case enCours
        case termine(texte: String, empreinte: UInt64)
        case rejete(String)
    }

    public mutating func recevoir(_ m: Message) -> Resultat {
        switch m {
        case .pressePapiersOffre(let o):
            guard Int(o.taille) <= tailleMax else { offre = nil; return .rejete("trop gros (\(o.taille) octets)") }
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
            guard let texte = String(validating: octets, as: UTF8.self) else { return .rejete("UTF-8 invalide") }
            return .termine(texte: texte, empreinte: o.empreinte)
        default:
            return .enCours
        }
    }
}
