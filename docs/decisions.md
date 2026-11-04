# Décisions de Slipway

Choix d'architecture pris pendant le développement.

## S1 — Logique dans un paquet SwiftPM testable sous Linux (2026-11-03)
**Contexte** : la session de développement tourne sous Linux, sans Xcode. **Décision** : toute la logique vit dans
`SlipwayKit` (modules `SlipwayCoeur`, `SlipwaySecurite`, `SlipwayMoteur`), sans AppKit ; les adaptateurs
macOS (`SlipwayMac`) sont derrière des protocoles (`InjecteurEntrees`, `CurseurLocal`, `LienReseau`,
`CanalDatagrammes`, `PressePapiersLocal`, `MagasinPairs`) avec doublures de test. `swift-crypto` (Apache-2.0) n'est
déclaré que sous Linux (`#if os(Linux)` dans le manifeste) ; macOS utilise CryptoKit. **Conséquence** : `swift test`
passe sous Linux et macOS ; le futur client Windows ne réécrit que les adaptateurs.

## S2 — Deux canaux, positions absolues, aucune file (2026-11-03)
TCP sans Nagle pour l'ordre et la fiabilité (clavier, clics, presse-papiers), UDP pour les mouvements et le
défilement, un datagramme par événement, numéroté. Chaque mouvement porte la **position absolue visée** chez le
Mac piloté : une perte se rattrape au paquet suivant sans dérive, et le piloté ne réapplique pas son accélération.
Injection immédiate, sans lissage par défaut. Fusion des mouvements seulement si l'émission UDP sature.
Repli automatique sur TCP si l'UDP ne passe pas.

## S3 — Appairage par comparaison de code avec engagement, plutôt que PAKE (2026-11-03)
Un PAKE (SPAKE2+) n'existe pas dans CryptoKit et aurait demandé une dépendance. Choix : échange X25519 éphémère
avec **engagement** du client (SHA-256 de sa clé avant de voir celle du serveur), code à 6 chiffres dérivé des
deux côtés, **confirmé par l'utilisateur sur les deux Mac** (saisir le code sur un seul Mac ne protégerait que ce
Mac). Identités Ed25519 épinglées ensuite. Pas de TLS : la même construction couvre TCP et UDP, et se réimplémente
à l'identique sous Windows (vecteurs de référence fournis).

## S4 — Session symétrique, disposition partagée (2026-11-03)
Chaque Mac peut piloter ou être piloté (pas de « serveur » fixe à la Synergy). Placement automatique identique vu
des deux côtés (plus petit identifiant à gauche) ; modifications manuelles partagées par message `Disposition`
avec révision de Lamport.

## S5 — Ports 24850 (TCP) et 24851 (UDP) (2026-11-03)
Fixes, hors de la plage de Synergy (24800-24804) pour pouvoir comparer les deux côte à côte.
