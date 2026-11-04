# Recette manuelle de Slipway (deux vrais Mac)

À cocher à chaque version. Ce qui est testé automatiquement (protocole, géométrie, machine à états, chiffrement,
moteur de bout en bout simulé avec pertes) n'est pas repris ici : seulement ce qu'aucune CI ne peut voir.

Matériel : Mac A (celui qui a la souris), Mac B. Idéalement une souris à haute fréquence, le trackpad, une Magic
Mouse, un clavier AZERTY. Noter la version de macOS des deux Mac.

## 0. Installation (sur chaque Mac)
- [ ] `make installer` ; Slipway apparaît dans la barre de menus, pas dans le Dock.
- [ ] Au premier lancement, l'invite « Réseau local » s'affiche : accepter. (Si elle ne vient pas : Réglages > Confidentialité > Réseau local.)
- [ ] Menu > « Demander » : accorder **Accessibilité** et **Surveillance de l'entrée** ; l'avertissement disparaît dans la seconde (sans relancer).
- [ ] Après un `make installer` suivant, les autorisations sont toujours là (identité de signature stable).

## 1. Appairage
- [ ] Les deux Mac se voient dans « Sur le réseau ». Cliquer « Appairer » sur l'un.
- [ ] Le **même code à 6 chiffres** s'affiche sur les deux ; confirmer sur l'un : il attend l'autre ; confirmer sur l'autre : connectés.
- [ ] « Refuser » sur un côté : rien n'est mémorisé, plus de demande.
- [ ] Quitter et relancer Slipway sur B : reconnexion automatique **sans code** en quelques secondes.
- [ ] Mac sur des comptes Apple différents : aucune différence.
- [ ] Secours : saisir l'IP de B dans le menu de A (Bonjour coupé) : la connexion se fait.

## 2. Passage par les bords et fluidité (le cœur)
- [ ] Disposition : B à droite de A par défaut sur **les deux** Mac (vérifier la fenêtre « Disposition » des deux côtés).
- [ ] Glisser B au-dessus de A dans l'éditeur de A : l'éditeur de B montre la même chose quelques instants après.
- [ ] Passer de A à B par le bord : le curseur apparaît sur B **à la même hauteur**, le curseur de A disparaît et ne bouge plus.
- [ ] Revenir sur A : le curseur réapparaît exactement au point de retour (miroir), visible, libre.
- [ ] **Fluidité** : cercles lents puis rapides sur B, avec souris puis trackpad. Aucune saccade visible, aucun « escalier » à vitesse lente.
- [ ] Mouvements très lents au trackpad sur B : le curseur avance au demi-point près (pas de blocage puis saut).
- [ ] Pousser lentement contre le bord : la bascule se fait quand même.
- [ ] Vitesse perçue sur B correcte ; si B a un écran de densité différente, régler « Vitesse sur chaque Mac » et vérifier.
- [ ] Coins morts à 30 pt : impossible de basculer dans un coin, possible ailleurs.
- [ ] B avec deux écrans : on passe de l'un à l'autre sur B sans repasser sur A.
- [ ] Latence affichée dans la barre de menus. Noter les valeurs (moyenne / 99e centile / gigue dans Diagnostic) :
  - Ethernet ou pont Thunderbolt : moy. ____ ms, p99 ____ ms (objectif < 5 ms)
  - Wi-Fi 5/6 GHz : moy. ____ ms, p99 ____ ms
  - Wi-Fi pendant un AirDrop : p99 ____ ms ; la fluidité reste-t-elle acceptable ?
- [ ] Diagnostic : « UDP : oui » des deux côtés (sinon le repli TCP fonctionne mais noter le pare-feu).

## 3. Clics, glisser, défilement
- [ ] Clic, double-clic (ouvre un dossier dans le Finder), triple-clic (sélectionne un paragraphe) sur B.
- [ ] Clic droit, clic milieu, boutons 4 et 5 (précédent/suivant dans Safari).
- [ ] Glisser une fenêtre sur B ; sélectionner du texte en glissant.
- [ ] Impossible de basculer en tenant le bouton (le curseur reste bloqué au bord) : comportement voulu.
- [ ] Défilement au trackpad dans Safari sur B : continu, avec **inertie** ; pincer n'est pas transmis (connu).
- [ ] Molette à crans : défile ligne par ligne.

## 4. Clavier
- [ ] Taper un texte AZERTY sur B (accents, @, €) : caractères corrects selon la disposition de B.
- [ ] Raccourcis sur B : ⌘C/⌘V, ⌘Tab, ⌘Espace, ⌃flèches (Mission Control, changement de bureau).
- [ ] Touches média (volume, lecture, luminosité) agissent sur B.
- [ ] Touche Fn/globe, Verr. Maj. : noter le comportement (à vérifier, peut nécessiter un ajustement).
- [ ] **Touches coincées** : tenir ⌘ sur A, passer sur B, relâcher : ⌘ n'est enfoncé nulle part (taper « a » sur A puis B).
- [ ] Tenir Maj sur B, revenir sur A, relâcher : B n'a pas Maj coincé.
- [ ] ⌃⌥⌘L pendant le pilotage : tout revient sur A, rien de coincé sur B.
- [ ] ⌃⌥⌘2 depuis A : le curseur apparaît au centre de B ; ⌃⌥⌘1 : retour sur A.

## 5. Saisie sécurisée
- [ ] Activer Terminal > « Entrée clavier sécurisée » sur A : icône cadenas, nom de l'app affiché ; la souris fonctionne encore sur B.
- [ ] Champ mot de passe sur B (piloté) : la frappe depuis A arrive (à vérifier sur macOS 26).

## 6. Robustesse
- [ ] Débrancher le câble / couper le Wi-Fi de A **en plein glissement** sur B : en 2 s au plus, B relâche le bouton tout seul, A retrouve son curseur.
- [ ] Rebrancher : reconnexion automatique en quelques secondes.
- [ ] Mettre A en veille pendant le pilotage : rien de coincé sur B ; au réveil, reconnexion.
- [ ] Verrouiller A (⌃⌘Q) pendant le pilotage : tout revient en local.
- [ ] Débrancher un écran externe de B : la disposition se met à jour, le passage marche toujours.
- [ ] Quitter Slipway pendant le pilotage : le curseur de A est visible et libre.
- [ ] Une heure d'usage : Diagnostic > « Réactivations du tap » reste faible (noter : ____).
- [ ] 3 Mac (si disponible) : passage A → B → C par les bords.

## 7. Presse-papiers
- [ ] Copier un texte sur A, passer sur B, coller : c'est le texte de A.
- [ ] Copier sur B, revenir sur A, coller : texte de B.
- [ ] Aucune boucle : le journal du diagnostic ne montre pas d'envois répétés du même texte.
- [ ] Un texte de 1 Mo passe ; une image n'est pas transmise (connu).

## 8. Comparaison avec Synergy (même matériel, même réseau)
- [ ] Sensation de fluidité : Slipway ____ / Synergy ____ (sur 10).
- [ ] Clics perdus constatés en 10 minutes : Slipway ____ / Synergy ____.
