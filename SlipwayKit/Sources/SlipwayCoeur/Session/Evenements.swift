/// Entrées et sorties de la machine à états. La session ne fait aucune entrée-sortie : elle reçoit des
/// événements datés (secondes, horloge monotone fournie par l'appelant) et rend des actions à exécuter.

/// Événement capturé sur ce Mac (souris et clavier physiques).
public enum EvenementLocal: Equatable, Sendable {
    /// `position` = position du curseur local (bloquée pendant le pilotage), `delta` = déplacement brut en points.
    case mouvement(position: Point, delta: Point)
    case bouton(BoutonSouris, enfonce: Bool, nbClics: UInt8, position: Point)
    case defilement(Defilement)
    case touche(usage: UInt16, enfonce: Bool, repetition: Bool, modificateurs: Modificateurs)
    case toucheSysteme(ToucheSysteme)
}

/// Événement à poster sur ce Mac (côté Mac piloté).
public enum Injection: Equatable, Sendable {
    case mouvement(position: Point, delta: Point, boutonsEnfonces: [BoutonSouris])
    case bouton(BoutonSouris, enfonce: Bool, nbClics: UInt8, position: Point)
    case defilement(Defilement, position: Point)
    case touche(usage: UInt16, enfonce: Bool, repetition: Bool, modificateurs: Modificateurs)
    case toucheSysteme(ToucheSysteme)
}

public enum Action: Equatable, Sendable {
    /// Canal fiable (TCP).
    case envoyer(Message, a: IdPair)
    /// Canal temps réel (datagrammes UDP).
    case envoyerTempsReel(Message, a: IdPair)
    /// Bloque le curseur local (il ne suit plus la souris) et le masque.
    case figerCurseurLocal
    /// Ramène le curseur local à ce point, le ré-associe à la souris et le ré-affiche.
    case libererCurseurLocal(a: Point)
    case injecter(Injection)
    /// Le presse-papiers local a peut-être changé : le comparer (changeCount) et le pousser aux pairs si besoin.
    case verifierPressePapiers
    /// Écrire ce texte dans le presse-papiers local (reçu d'un pair).
    case ecrirePressePapiers(String)
    /// Fermer le lien avec ce pair (délai dépassé).
    case couperLien(IdPair)
    case journal(String)
}

/// Raccourcis interceptés avant tout le reste (même pendant le pilotage).
public struct Raccourcis: Equatable, Sendable, Codable {
    /// Touche (usage HID) qui, avec les modificateurs `modificateurs`, rend tout en local. Défaut : ⌃⌥⌘L.
    public var toucheToutLocal: UInt16
    /// Avec les mêmes modificateurs, 1…9 basculent vers le n-ième Mac (ordre gauche → droite de la disposition).
    public var modificateurs: [UInt32]

    public init(toucheToutLocal: UInt16 = CodeTouche.l, modificateurs: [Modificateurs] = [.ctrl, .option, .cmd]) {
        self.toucheToutLocal = toucheToutLocal
        self.modificateurs = modificateurs.map(\.rawValue)
    }

    var groupes: [Modificateurs] { modificateurs.map { Modificateurs(rawValue: $0) } }
}
