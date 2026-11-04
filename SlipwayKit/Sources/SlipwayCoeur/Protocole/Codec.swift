/// Encodage et décodage des trames. Format (voir docs/protocole.md) :
///
///     type (u8) | drapeaux (u8) | longueur de charge (u16) | séquence (u32) | charge…
///
/// Tout est petit-boutiste. Un type inconnu est rendu en `.inconnu` (ignoré), une charge plus longue que prévu
/// pour un type connu est acceptée (champs ajoutés par une mineure future), une charge trop courte est une erreur.
public enum Codec {
    public static func encoder(_ trame: Trame) -> [UInt8] {
        var charge = EcrivainOctets()
        encoderCharge(trame.message, dans: &charge)
        precondition(charge.octets.count <= Int(UInt16.max), "charge trop longue pour une trame")
        var e = EcrivainOctets(capacite: Protocole.tailleEntete + charge.octets.count)
        e.u8(trame.message.type)
        e.u8(trame.drapeaux)
        e.u16(UInt16(charge.octets.count))
        e.u32(trame.sequence)
        e.brut(charge.octets)
        return e.octets
    }

    public static func encoder(_ message: Message, sequence: UInt32 = 0) -> [UInt8] {
        encoder(Trame(sequence: sequence, message: message))
    }

    public static func decoder(_ octets: [UInt8]) throws(ErreurDecodage) -> Trame {
        var l = LecteurOctets(octets)
        let type = try l.u8()
        let drapeaux = try l.u8()
        let longueur = Int(try l.u16())
        let sequence = try l.u32()
        guard l.restant == longueur else { throw .longueurIncoherente(annoncee: longueur, reelle: l.restant) }
        let message = try decoderCharge(type: type, lecteur: &l)
        return Trame(sequence: sequence, message: message, drapeaux: drapeaux)
    }

    // MARK: - Charges

    static func encoderCharge(_ message: Message, dans e: inout EcrivainOctets) {
        switch message {
        case .bonjourClient(let b):
            e.brut(Protocole.magie); e.u8(b.versionMajeure); e.u8(b.versionMineure); e.u32(b.capacites.rawValue)
            e.brut(fixe(b.cleIdentite, 32)); e.brut(fixe(b.engagement, 32)); e.texteCourt(b.nom, maximum: 64)
        case .bonjourServeur(let b):
            e.brut(Protocole.magie); e.u8(b.versionMajeure); e.u8(b.versionMineure); e.u32(b.capacites.rawValue)
            e.brut(fixe(b.cleIdentite, 32)); e.brut(fixe(b.cleEphemere, 32)); e.brut(fixe(b.alea, 16))
            e.u16(b.portUDP); e.texteCourt(b.nom, maximum: 64)
        case .revelation(let r):
            e.brut(fixe(r.cleEphemere, 32)); e.brut(fixe(r.alea, 16))
        case .preuve(let signature):
            e.brut(fixe(signature, 64))
        case .confirmationAppairage, .toutRelacher:
            break
        case .auRevoir(let raison, let texte):
            e.u8(raison.rawValue); e.texteLong(texte, maximum: 512)
        case .ecrans(let ecrans):
            let liste = ecrans.prefix(32)
            e.u8(UInt8(liste.count))
            for ec in liste {
                e.u32(ec.id); e.f32(ec.x); e.f32(ec.y); e.f32(ec.largeur); e.f32(ec.hauteur); e.f32(ec.echelle); e.booleen(ec.principal)
            }
        case .disposition(let revision, let places):
            let liste = places.prefix(32)
            e.u64(revision)
            e.u8(UInt8(liste.count))
            for p in liste { e.brut(fixe(p.id, 8)); e.f32(p.x); e.f32(p.y) }
        case .role(let principal):
            e.booleen(principal)
        case .entree(let en):
            e.f32(en.x); e.f32(en.y); e.u32(en.modificateurs.rawValue)
        case .sortie(let raison):
            e.u8(raison.rawValue)
        case .bouton(let b):
            e.u8(b.bouton.rawValue); e.booleen(b.enfonce); e.u8(b.nbClics); e.f32(b.x); e.f32(b.y)
        case .touche(let t):
            e.u16(t.usage); e.booleen(t.enfonce); e.booleen(t.repetition); e.u32(t.modificateurs.rawValue)
        case .toucheSysteme(let t):
            e.u16(t.usage); e.booleen(t.enfonce); e.booleen(t.repetition)
        case .pressePapiersOffre(let o):
            e.u32(o.idTransfert); e.u8(o.format.rawValue); e.u32(o.taille); e.u64(o.empreinte)
        case .pressePapiersMorceau(let m):
            e.u32(m.idTransfert); e.u32(m.decalage); e.brut(m.octets)
        case .ping(let h), .pong(let h):
            e.u64(h)
        case .mouvement(let m):
            e.f32(m.dx); e.f32(m.dy); e.f32(m.x); e.f32(m.y); e.u8(m.boutons)
        case .defilement(let d):
            e.f32(d.dxPoints); e.f32(d.dyPoints); e.f32(d.dxLignes); e.f32(d.dyLignes)
            e.u8(d.phase.rawValue); e.u8(d.inertie.rawValue); e.booleen(d.continu)
        case .inconnu(_, let charge):
            e.brut(charge)
        }
    }

    static func decoderCharge(type: UInt8, lecteur l: inout LecteurOctets) throws(ErreurDecodage) -> Message {
        guard let t = TypeMessage(rawValue: type) else { return .inconnu(type: type, charge: l.toutLeReste()) }
        switch t {
        case .bonjourClient:
            let (maj, min, caps) = try entetePoigneeDeMain(&l)
            return .bonjourClient(BonjourClient(capacites: caps, cleIdentite: try l.brut(32), engagement: try l.brut(32),
                                                nom: try l.texteCourt(), versionMajeure: maj, versionMineure: min))
        case .bonjourServeur:
            let (maj, min, caps) = try entetePoigneeDeMain(&l)
            return .bonjourServeur(BonjourServeur(capacites: caps, cleIdentite: try l.brut(32), cleEphemere: try l.brut(32),
                                                  alea: try l.brut(16), portUDP: try l.u16(), nom: try l.texteCourt(),
                                                  versionMajeure: maj, versionMineure: min))
        case .revelation:
            return .revelation(Revelation(cleEphemere: try l.brut(32), alea: try l.brut(16)))
        case .preuve:
            return .preuve(signature: try l.brut(64))
        case .confirmationAppairage:
            return .confirmationAppairage
        case .auRevoir:
            let brute = try l.u8()
            return .auRevoir(raison: RaisonDepart(rawValue: brute) ?? .erreurProtocole, texte: try l.texteLong())
        case .ecrans:
            let n = Int(try l.u8())
            var liste: [EcranDecrit] = []
            for _ in 0..<n {
                let ecran = EcranDecrit(id: try l.u32(), x: try l.f32(), y: try l.f32(), largeur: try l.f32(), hauteur: try l.f32(),
                                        echelle: try l.f32(), principal: try l.booleen())
                guard ecran.largeur > 0, ecran.hauteur > 0, ecran.echelle > 0 else { throw .valeurInvalide("écran vide") }
                liste.append(ecran)
            }
            return .ecrans(liste)
        case .disposition:
            let revision = try l.u64()
            let n = Int(try l.u8())
            var places: [PlaceDecrite] = []
            for _ in 0..<n { places.append(PlaceDecrite(id: try l.brut(8), x: try l.f32(), y: try l.f32())) }
            return .disposition(revision: revision, places: places)
        case .role:
            return .role(principal: try l.booleen())
        case .entree:
            return .entree(Entree(x: try l.f32(), y: try l.f32(), modificateurs: Modificateurs(rawValue: try l.u32())))
        case .sortie:
            return .sortie(RaisonSortie(rawValue: try l.u8()) ?? .bascule)
        case .bouton:
            let numero = try l.u8()
            guard numero < 32 else { throw .valeurInvalide("bouton \(numero)") }
            return .bouton(EvenementBouton(bouton: BoutonSouris(rawValue: numero), enfonce: try l.booleen(), nbClics: try l.u8(),
                                           x: try l.f32(), y: try l.f32()))
        case .touche:
            return .touche(EvenementTouche(usage: try l.u16(), enfonce: try l.booleen(), repetition: try l.booleen(),
                                           modificateurs: Modificateurs(rawValue: try l.u32())))
        case .toucheSysteme:
            return .toucheSysteme(ToucheSysteme(usage: try l.u16(), enfonce: try l.booleen(), repetition: try l.booleen()))
        case .toutRelacher:
            return .toutRelacher
        case .pressePapiersOffre:
            let id = try l.u32()
            let brut = try l.u8()
            guard let format = FormatPressePapiers(rawValue: brut) else { throw .valeurInvalide("format \(brut)") }
            return .pressePapiersOffre(OffrePressePapiers(idTransfert: id, format: format, taille: try l.u32(), empreinte: try l.u64()))
        case .pressePapiersMorceau:
            return .pressePapiersMorceau(MorceauPressePapiers(idTransfert: try l.u32(), decalage: try l.u32(), octets: l.toutLeReste()))
        case .ping:
            return .ping(horodatage: try l.u64())
        case .pong:
            return .pong(horodatage: try l.u64())
        case .mouvement:
            return .mouvement(Mouvement(dx: try l.f32(), dy: try l.f32(), x: try l.f32(), y: try l.f32(), boutons: try l.u8()))
        case .defilement:
            let dxP = try l.f32(), dyP = try l.f32(), dxL = try l.f32(), dyL = try l.f32()
            let phase = PhaseDefilement(rawValue: try l.u8()) ?? .aucune
            let inertie = PhaseInertie(rawValue: try l.u8()) ?? .aucune
            return .defilement(Defilement(dxPoints: dxP, dyPoints: dyP, dxLignes: dxL, dyLignes: dyL, phase: phase, inertie: inertie,
                                          continu: try l.booleen()))
        }
    }

    private static func entetePoigneeDeMain(_ l: inout LecteurOctets) throws(ErreurDecodage) -> (UInt8, UInt8, Capacites) {
        guard try l.brut(4) == Protocole.magie else { throw .magiqueInvalide }
        let majeure = try l.u8()
        let mineure = try l.u8()
        guard majeure == Protocole.versionMajeure else { throw .versionIncompatible(majeure: majeure) }
        return (majeure, mineure, Capacites(rawValue: try l.u32()))
    }

    /// Ramène un tableau à une taille fixe (complète par des zéros ou tronque) : l'encodage ne plante jamais.
    private static func fixe(_ octets: [UInt8], _ taille: Int) -> [UInt8] {
        if octets.count == taille { return octets }
        return Array((octets + [UInt8](repeating: 0, count: taille)).prefix(taille))
    }
}
