import SlipwayCoeur

/// Tout ce qu'une poignée de main réussie produit.
public struct MaterielSession: Equatable, Sendable {
    public enum Role: UInt8, Sendable { case client = 0x43, serveur = 0x53 }   // 'C', 'S'

    public let role: Role
    public let clePairIdentite: [UInt8]
    public let idPair: IdPair
    public let nomPair: String
    /// Intersection des capacités des deux côtés.
    public let capacites: Capacites
    /// Port UDP du pair (connu du client seulement ; le serveur répond à l'adresse source des datagrammes).
    public let portUDPPair: UInt16?
    public let cleEnvoiFlux: [UInt8]
    public let cleReceptionFlux: [UInt8]
    public let cleEnvoiDatagrammes: [UInt8]
    public let cleReceptionDatagrammes: [UInt8]
    /// Identifiant du canal temps réel (8 octets), placé en clair dans chaque datagramme.
    public let idCanalTempsReel: [UInt8]
    /// Code à 6 chiffres affiché sur les deux Mac lors du premier appairage.
    public let codeVerification: String
    public let empreinteTranscription: [UInt8]
}

/// Poignée de main Slipway v1 (spécification : docs/protocole.md). Valeur pure, sans entrée-sortie :
///
///     client → serveur : BonjourClient  (clé d'identité, engagement = SHA-256(clé éphémère ‖ aléa))   en clair
///     serveur → client : BonjourServeur (clé d'identité, clé éphémère, aléa, port UDP)                 en clair
///     client → serveur : Revelation     (clé éphémère, aléa : le serveur vérifie l'engagement)         en clair
///     les deux         : Preuve         (signature Ed25519 de la transcription)                        scellé
///
/// L'engagement empêche un intermédiaire de « fabriquer » une clé qui donnerait le même code à 6 chiffres
/// des deux côtés : il devrait choisir sa clé avant de voir celle de l'autre (une chance sur un million).
public struct PoigneeDeMain: Sendable {
    public enum Etat: Equatable, Sendable {
        case initial
        case attenteBonjourServeur
        case attenteBonjourClient
        case attenteRevelation
        case attentePreuve
        case authentifiee
        case echec(ErreurSecurite)
    }

    /// Ce qu'une étape demande d'envoyer.
    public struct Sortie: Equatable, Sendable {
        /// Trames à envoyer en clair (déjà encodées : la transcription porte sur ces octets exacts).
        public var enClair: [[UInt8]] = []
        /// Messages à envoyer scellés, une fois `materiel` connu.
        public var scelles: [Message] = []
        public var materiel: MaterielSession?
    }

    public let role: MaterielSession.Role
    public private(set) var etat: Etat
    public private(set) var materiel: MaterielSession?

    private let identite: Identite
    private let nom: String
    private let capacites: Capacites
    private let portUDP: UInt16
    private let alea: SourceAlea
    private var transcription: [UInt8] = []
    private var ephemerePrivee: [UInt8] = []
    private var aleaLocal: [UInt8] = []
    private var bonjourClientRecu: BonjourClient?
    private var bonjourServeurRecu: BonjourServeur?

    public init(role: MaterielSession.Role, identite: Identite, nom: String, capacites: Capacites = .toutes,
                portUDP: UInt16 = 0, alea: SourceAlea = AleaSysteme()) {
        self.role = role
        self.identite = identite
        self.nom = nom
        self.capacites = capacites
        self.portUDP = portUDP
        self.alea = alea
        self.etat = role == .client ? .initial : .attenteBonjourClient
    }

    /// Client uniquement : première trame à envoyer.
    public mutating func demarrer() throws(ErreurSecurite) -> Sortie {
        guard role == .client, etat == .initial else { throw .messageInattendu("démarrage") }
        ephemerePrivee = alea.octets(32)
        aleaLocal = alea.octets(16)
        let pub = try Derivation.clePubliqueX25519(privee: ephemerePrivee)
        let message = Message.bonjourClient(BonjourClient(capacites: capacites, cleIdentite: identite.clePublique,
                                                          engagement: Derivation.sha256(pub + aleaLocal), nom: nom))
        let trame = Codec.encoder(message)
        transcription += trame
        etat = .attenteBonjourServeur
        return Sortie(enClair: [trame])
    }

    /// Trame reçue en clair pendant la poignée de main (octets exacts tels que reçus).
    public mutating func recevoirEnClair(_ trame: [UInt8]) throws(ErreurSecurite) -> Sortie {
        let message: Message
        do { message = try Codec.decoder(trame).message } catch {
            if case .versionIncompatible(let v) = error { throw echouer(.versionIncompatible(v)) }
            throw echouer(.messageInattendu("trame illisible : \(error)"))
        }
        switch (etat, message) {
        case (.attenteBonjourClient, .bonjourClient(let b)):
            guard b.cleIdentite.count == 32 else { throw echouer(.cleInvalide) }
            bonjourClientRecu = b
            transcription += trame
            ephemerePrivee = alea.octets(32)
            aleaLocal = alea.octets(16)
            let reponse = Codec.encoder(.bonjourServeur(BonjourServeur(
                capacites: capacites, cleIdentite: identite.clePublique,
                cleEphemere: try Derivation.clePubliqueX25519(privee: ephemerePrivee), alea: aleaLocal, portUDP: portUDP, nom: nom)))
            transcription += reponse
            etat = .attenteRevelation
            return Sortie(enClair: [reponse])

        case (.attenteBonjourServeur, .bonjourServeur(let b)):
            bonjourServeurRecu = b
            transcription += trame
            let revelation = Codec.encoder(.revelation(Revelation(cleEphemere: try Derivation.clePubliqueX25519(privee: ephemerePrivee),
                                                                 alea: aleaLocal)))
            transcription += revelation
            let m = try deriver(ephemerePair: b.cleEphemere, identitePair: b.cleIdentite, nomPair: b.nom,
                                capacitesPair: b.capacites, portUDPPair: b.portUDP)
            return Sortie(enClair: [revelation], scelles: [.preuve(signature: try signerPreuve())], materiel: m)

        case (.attenteRevelation, .revelation(let r)):
            guard let b = bonjourClientRecu else { throw echouer(.messageInattendu("révélation sans bonjour")) }
            guard Derivation.sha256(r.cleEphemere + r.alea) == b.engagement else { throw echouer(.engagementInvalide) }
            transcription += trame
            let m = try deriver(ephemerePair: r.cleEphemere, identitePair: b.cleIdentite, nomPair: b.nom,
                                capacitesPair: b.capacites, portUDPPair: nil)
            return Sortie(scelles: [.preuve(signature: try signerPreuve())], materiel: m)

        default:
            throw echouer(.messageInattendu("\(message.type) dans l'état \(etat)"))
        }
    }

    /// Preuve reçue (déjà ouverte par le canal scellé) : vérifie que le pair possède la clé d'identité annoncée.
    public mutating func recevoirPreuve(_ signature: [UInt8]) throws(ErreurSecurite) {
        guard etat == .attentePreuve, let m = materiel else { throw echouer(.messageInattendu("preuve")) }
        let rolePair: MaterielSession.Role = role == .client ? .serveur : .client
        let message = Self.messagePreuve(role: rolePair, empreinte: m.empreinteTranscription)
        guard Identite.verifier(signature: signature, message: message, clePublique: m.clePairIdentite) else {
            throw echouer(.signatureInvalide)
        }
        etat = .authentifiee
    }

    public static func messagePreuve(role: MaterielSession.Role, empreinte: [UInt8]) -> [UInt8] {
        Array("SLPW preuve v1".utf8) + [role.rawValue] + empreinte
    }

    private mutating func signerPreuve() throws(ErreurSecurite) -> [UInt8] {
        try identite.signer(Self.messagePreuve(role: role, empreinte: materiel!.empreinteTranscription))
    }

    private mutating func deriver(ephemerePair: [UInt8], identitePair: [UInt8], nomPair: String,
                                  capacitesPair: Capacites, portUDPPair: UInt16?) throws(ErreurSecurite) -> MaterielSession {
        guard identitePair.count == 32 else { throw echouer(.cleInvalide) }
        let secret: [UInt8]
        do { secret = try Derivation.secretPartage(privee: ephemerePrivee, publiquePair: ephemerePair) } catch { throw echouer(error) }
        let m = Self.deriverMateriel(secret: secret, transcription: transcription, role: role, clePairIdentite: identitePair,
                                     nomPair: nomPair, capacites: capacites.intersection(capacitesPair), portUDPPair: portUDPPair)
        materiel = m
        ephemerePrivee = []
        etat = .attentePreuve
        return m
    }

    /// Dérivation des clés (publique pour les vecteurs de référence).
    public static func deriverMateriel(secret: [UInt8], transcription: [UInt8], role: MaterielSession.Role, clePairIdentite: [UInt8],
                                       nomPair: String, capacites: Capacites, portUDPPair: UInt16?) -> MaterielSession {
        let empreinte = Derivation.sha256(transcription)
        func k(_ etiquette: String, _ n: Int = 32) -> [UInt8] { Derivation.hkdf(secret, sel: empreinte, etiquette: etiquette, octets: n) }
        let fluxCS = k("tcp c>s"), fluxSC = k("tcp s>c"), dgCS = k("udp c>s"), dgSC = k("udp s>c")
        let client = role == .client
        return MaterielSession(
            role: role, clePairIdentite: clePairIdentite, idPair: IdPair(cleIdentite: clePairIdentite), nomPair: nomPair,
            capacites: capacites, portUDPPair: portUDPPair,
            cleEnvoiFlux: client ? fluxCS : fluxSC, cleReceptionFlux: client ? fluxSC : fluxCS,
            cleEnvoiDatagrammes: client ? dgCS : dgSC, cleReceptionDatagrammes: client ? dgSC : dgCS,
            idCanalTempsReel: k("udp id", 8), codeVerification: Derivation.codeSixChiffres(k("sas", 4)),
            empreinteTranscription: empreinte)
    }

    private mutating func echouer(_ e: ErreurSecurite) -> ErreurSecurite {
        etat = .echec(e)
        ephemerePrivee = []
        return e
    }
}
