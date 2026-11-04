# Protocole Slipway, version 1.0

Ce document fait foi pour toute implémentation (macOS aujourd'hui, Windows peut-être demain). Le code Swift
(`SlipwayKit/Sources/SlipwayCoeur/Protocole`, `SlipwaySecurite`) en est l'implémentation de référence, vérifiée par
les **fichiers de référence** de `docs/octets-de-reference/` : une autre implémentation doit produire et relire
exactement ces octets.

Conventions : tous les entiers et flottants sont **petit-boutistes** (little-endian). `f32` = IEEE 754 simple
précision ; une valeur NaN ou infinie est une erreur. `bool` = 1 octet valant 0 ou 1 (toute autre valeur est une
erreur). Les textes sont en UTF-8 précédés de leur longueur (`u8` pour un texte court, `u16` pour un texte long),
jamais tronqués au milieu d'un caractère.

## 1. Vue d'ensemble

Deux Mac (ou plus, en maillage complet) se relient par **deux canaux** :

| Canal | Transport | Sert à | Port |
|---|---|---|---|
| Fiable | TCP, Nagle coupé (`TCP_NODELAY`), keepalive | poignée de main, appairage, écrans, disposition, entrée/sortie, clics, clavier, presse-papiers, battements de secours | 24850 |
| Temps réel | UDP, un datagramme par événement | mouvements de souris, défilement, battements de cœur et mesure de latence | 24851 |

Un mouvement perdu n'est **jamais retransmis** : le suivant le remplace (chaque mouvement porte la position
absolue visée). C'est ce qui évite les saccades « en rafale » d'un flux TCP qui retransmet un vieux mouvement.
Si l'UDP ne passe pas (pare-feu), les messages temps réel sont envoyés sur le canal fiable (repli).

Découverte : service Bonjour `_slipway._tcp` sur le port TCP, enregistrement TXT `id=<16 hex>` (identifiant du Mac)
et `v=1` (version majeure). Pour éviter les doubles connexions, seul le Mac dont l'identifiant est le plus petit
(ordre lexicographique) se connecte automatiquement à un pair déjà appairé. Si deux connexions s'établissent quand
même, chaque côté garde celle dont le **client** a le plus petit identifiant et ferme l'autre (`AuRevoir`, raison 4).

Rôles : le **client** est celui qui a ouvert la connexion TCP, le **serveur** celui qui l'a acceptée. Ces rôles ne
concernent que la poignée de main ; ensuite les deux Mac sont symétriques (chacun peut piloter l'autre).

## 2. Trame

Toute unité du protocole est une **trame** :

| Octets | Champ | Type | Remarque |
|---|---|---|---|
| 0 | type | u8 | voir §4 |
| 1 | drapeaux | u8 | 0 en v1 ; ignorés en lecture |
| 2-3 | longueur | u16 | longueur de la charge (hors en-tête) |
| 4-7 | séquence | u32 | compteur de l'émetteur, par canal et par connexion, commence à 1 (0 pour la poignée de main) |
| 8… | charge | | `longueur` octets |

Règles de lecture :
- longueur annoncée ≠ octets reçus : erreur ;
- **type inconnu** : la trame est ignorée sans erreur (compatibilité avec une mineure future) ;
- charge **plus longue** que prévu pour un type connu : les octets en trop sont ignorés (champs ajoutés par une mineure) ;
- charge trop courte : erreur.

Taille maximale d'une trame : 8 + 65 535 octets.

## 3. Encapsulation sur les canaux

### 3.1 Canal fiable (TCP)

Le flux TCP est une suite d'**enregistrements** : `longueur (u16) | corps`. Le corps est :
- pendant la poignée de main, une trame **en clair** (`BonjourClient`, `BonjourServeur`, `Revelation`, `AuRevoir` de refus de version) ;
- ensuite, une trame **scellée** : `ChaCha20-Poly1305(trame)` = texte chiffré ‖ étiquette (16 octets), sans données
  associées, avec un nonce implicite (§5.4) : 0 pour le premier enregistrement scellé de chaque sens, puis 1, 2…

Bascule en mode scellé : le client scelle tout ce qu'il envoie après sa `Revelation` et ouvre tout ce qu'il reçoit
après `BonjourServeur` ; le serveur scelle tout ce qu'il envoie après avoir reçu la `Revelation` et ouvre tout ce
qu'il reçoit ensuite. Un enregistrement qui ne s'ouvre pas ferme la connexion.

### 3.2 Canal temps réel (UDP)

Chaque datagramme :

| Octets | Champ |
|---|---|
| 0 | version d'encapsulation = 1 |
| 1-8 | identifiant du canal (8 octets, dérivé §5.3) |
| 9-16 | compteur u64 (nonce, §5.4), propre à chaque sens |
| 17… | `ChaCha20-Poly1305(trame)` avec les octets 0-16 comme **données associées**, puis l'étiquette (16 octets) |

Le récepteur retrouve la connexion par l'identifiant de canal, refuse tout compteur déjà vu ou plus ancien de
64 positions que le plus grand accepté (fenêtre anti-rejeu, comme IPsec), puis authentifie. Le compteur n'est
marqué « vu » qu'après authentification. Le serveur apprend l'adresse UDP du client au premier datagramme
authentique (et suit ses changements). Le client ouvre le canal vers l'adresse IP de la connexion TCP et le port
UDP annoncé dans `BonjourServeur`, puis envoie un `Ping` tout de suite.

Seuls `Ping`, `Pong`, `Mouvement` et `Defilement` sont admis sur ce canal ; les autres types y sont ignorés.

## 4. Messages

| Type | Nom | Canal | Charge |
|---|---|---|---|
| 0x01 | BonjourClient | fiable, clair | magie `SLPW` (4) · majeure u8 · mineure u8 · capacités u32 · clé d'identité Ed25519 (32) · engagement (32) · nom (texte court, ≤ 64 octets) |
| 0x02 | BonjourServeur | fiable, clair | magie · majeure · mineure · capacités · clé d'identité (32) · clé éphémère X25519 (32) · aléa (16) · port UDP u16 · nom |
| 0x03 | Revelation | fiable, clair | clé éphémère X25519 du client (32) · aléa (16) |
| 0x04 | Preuve | fiable | signature Ed25519 (64), §5.5 |
| 0x05 | ConfirmationAppairage | fiable | vide |
| 0x06 | AuRevoir | fiable (clair seulement pour un refus de version) | raison u8 · texte long (≤ 512 octets) |
| 0x07 | Ecrans | fiable | nombre u8 (≤ 32) · pour chaque écran : id u32 · x f32 · y f32 · largeur f32 · hauteur f32 · échelle f32 · principal bool |
| 0x08 | Disposition | fiable | révision u64 · nombre u8 (≤ 32) · pour chaque Mac : identifiant (8 octets) · décalage x f32 · décalage y f32 |
| 0x10 | Entree | fiable | x f32 · y f32 · modificateurs u32 |
| 0x11 | Sortie | fiable | raison u8 |
| 0x12 | Bouton | fiable | bouton u8 (< 32) · enfoncé bool · nombre de clics u8 · x f32 · y f32 |
| 0x13 | Touche | fiable | usage u16 · enfoncé bool · répétition bool · modificateurs u32 |
| 0x14 | ToucheSysteme | fiable | usage consommateur u16 · enfoncé bool · répétition bool |
| 0x15 | ToutRelacher | fiable | vide |
| 0x20 | PressePapiersOffre | fiable | id de transfert u32 · format u8 (1 = texte UTF-8) · taille u32 · empreinte FNV-1a 64 u64 |
| 0x21 | PressePapiersMorceau | fiable | id de transfert u32 · décalage u32 · octets (reste de la charge, ≤ 32 Kio) |
| 0x30 | Ping | les deux | horodatage u64 (nanosecondes, horloge monotone de l'émetteur) |
| 0x31 | Pong | les deux | horodatage u64 recopié du Ping |
| 0x40 | Mouvement | temps réel | dx f32 · dy f32 · x f32 · y f32 · boutons u8 |
| 0x41 | Defilement | temps réel | dx points f32 · dy points f32 · dx lignes f32 · dy lignes f32 · phase u8 · inertie u8 · continu bool |

Un exemple octet par octet de **chaque** message est dans `docs/octets-de-reference/<nom>.hex` (commentaires `#`,
puis l'hexadécimal).

### 4.1 Valeurs

- **Capacités** (champ de bits) : bit 0 pointeur, bit 1 clavier, bit 2 presse-papiers texte. On utilise l'intersection.
- **Raisons d'AuRevoir** : 0 normal, 1 version incompatible, 2 appairage refusé, 3 authentification échouée, 4 occupé
  (connexion en double), 5 erreur de protocole.
- **Raisons de Sortie** : 0 bascule, 1 panique (« tout rendre en local »), 2 veille ou verrouillage, 3 arrêt de l'app, 4 délai.
- **Boutons** : 0 gauche, 1 droit, 2 milieu, 3 et 4 latéraux, jusqu'à 31. Dans `Mouvement.boutons`, bit n = bouton n enfoncé (n < 8).
- **Modificateurs** (u32) : bits 0-7 = Ctrl, Maj, Alt/Option, Cmd/Windows **gauches** puis les mêmes **droits**
  (même ordre que le rapport clavier HID « boot ») ; bit 8 Verr. Maj. ; bit 9 Fn. Chaque événement clavier porte
  l'état **complet** après l'événement : le récepteur se resynchronise toujours.
- **Usage de touche** : usage HID de la page clavier 0x07 (`0x04` = A, `0x28` = Entrée, `0xE0`-`0xE7` modificateurs…).
  On transmet la **touche physique**, pas le caractère : la disposition (AZERTY, QWERTY) s'applique chez le
  récepteur. Seule extension : `0x0300` = touche Fn/globe d'Apple. Table macOS ↔ HID : `TableTouchesMac`.
  Attention Windows : sur les claviers ISO d'Apple, macOS échange les touches `§`/`<>` (usages 0x35 et 0x64) ;
  la table Slipway suit les codes macOS (`kVK_ISO_Section` ↔ 0x64, `kVK_ANSI_Grave` ↔ 0x35).
- **Usage consommateur** (page HID 0x0C) : 0xE9 volume +, 0xEA volume −, 0xE2 muet, 0xCD lecture/pause,
  0xB5 suivant, 0xB6 précédent, 0xB3 avance, 0xB4 retour, 0xB8 éjecter, 0x6F/0x70 luminosité +/−,
  0x79/0x7A/0x7C rétroéclairage clavier +/−/bascule.
- **Phase de défilement** : 0 aucune, 1 début, 2 changement, 3 fin, 4 annulé, 5 peut commencer.
  **Inertie** : 0 aucune, 1 début, 2 en cours, 3 fin. `continu` = pavé tactile ou Magic Mouse (défilement au pixel).

### 4.2 Coordonnées

Chaque Mac décrit ses écrans en **points** (jamais en pixels) dans son propre espace global : origine en haut à
gauche de l'écran principal, y vers le bas, coordonnées négatives pour les écrans à gauche ou au-dessus (espace
global Quartz). Côté Windows : coordonnées de l'écran virtuel en pixels indépendants de la densité.

Les positions d'`Entree`, `Mouvement` et `Bouton` sont dans l'espace **du Mac qui reçoit**. C'est le Mac qui
pilote qui calcule tout (il connaît les écrans de l'autre par `Ecrans`) ; le Mac piloté se contente de borner la
position à ses écrans et de la poster telle quelle (il ne réapplique pas son accélération).

La **disposition** place chaque Mac dans un bureau virtuel commun : position virtuelle = position locale + décalage
du Mac. Le placement automatique est identique vu de chaque Mac : un Mac dont l'identifiant est plus petit que
ceux de tous les autres va à gauche de l'ensemble, sinon à droite, centré verticalement. Quand l'utilisateur
modifie la disposition, son Mac l'envoie avec une révision = (plus grande révision connue) + 1 ; un Mac n'applique
une `Disposition` reçue que si sa révision est plus grande que la sienne (horloge de Lamport).

## 5. Sécurité

Primitives : X25519, Ed25519, SHA-256, HKDF-SHA256, ChaCha20-Poly1305 (CryptoKit sur macOS, libsodium ou
équivalent ailleurs). Aucun serveur tiers, aucun compte, aucune donnée hors du réseau local.

### 5.1 Identité

Chaque Mac possède une paire de clés **Ed25519** durable (dans le Trousseau sur macOS). Son **identifiant** est
l'écriture hexadécimale (16 caractères) des 8 premiers octets de la clé publique.

### 5.2 Poignée de main

```
client → serveur : BonjourClient   clé d'identité C, engagement = SHA-256(clé éphémère C ‖ aléa C)
serveur → client : BonjourServeur  clé d'identité S, clé éphémère S, aléa S, port UDP
client → serveur : Revelation      clé éphémère C, aléa C   (le serveur vérifie l'engagement)
les deux         : Preuve          (scellée)
```

- Version majeure différente : le serveur répond `AuRevoir` en clair (raison 1) et ferme.
- `transcription` = concaténation des **octets exacts** des trames `BonjourClient`, `BonjourServeur` et `Revelation`
  (en-têtes compris), et `empreinte = SHA-256(transcription)`.
- `secret = X25519(clé éphémère privée, clé éphémère du pair)` (32 octets bruts).

L'engagement oblige le client à choisir sa clé éphémère avant de voir celle du serveur : un intermédiaire ne peut
pas chercher des clés qui donneraient le même code à 6 chiffres des deux côtés (une chance sur un million par essai).

### 5.3 Dérivation

`K(étiquette, n) = HKDF-SHA256(ikm = secret, sel = empreinte, info = "SLPW v1 " + étiquette, n octets)`

| Étiquette | n | Usage |
|---|---|---|
| `tcp c>s` | 32 | canal fiable, client vers serveur |
| `tcp s>c` | 32 | canal fiable, serveur vers client |
| `udp c>s` | 32 | canal temps réel, client vers serveur |
| `udp s>c` | 32 | canal temps réel, serveur vers client |
| `udp id` | 8 | identifiant du canal temps réel |
| `sas` | 4 | code de vérification |

**Code à 6 chiffres** = (les 4 octets `sas` lus en gros-boutiste) modulo 1 000 000, écrit sur 6 chiffres avec zéros à gauche.

### 5.4 Nonces

Nonce ChaCha20-Poly1305 (12 octets) = 4 octets nuls ‖ compteur u64 petit-boutiste. Chaque clé ne sert que dans un
sens : un compteur n'est jamais réutilisé avec la même clé.

### 5.5 Preuve et appairage

`Preuve` = signature Ed25519, par la clé d'identité de l'émetteur, de `"SLPW preuve v1" ‖ rôle ‖ empreinte`, où
rôle = `0x43` (« C ») pour le client et `0x53` (« S ») pour le serveur. Une preuve invalide ferme la connexion.

- **Pair déjà appairé** (sa clé d'identité est épinglée) : la connexion est établie dès la preuve vérifiée.
- **Premier appairage** : chaque Mac affiche le code à 6 chiffres. L'utilisateur vérifie qu'il est **identique sur
  les deux écrans** et confirme sur chacun ; chaque confirmation envoie `ConfirmationAppairage`. Quand un Mac a sa
  propre confirmation et celle du pair, il épingle la clé d'identité du pair et établit la connexion. Un refus
  envoie `AuRevoir` (raison 2).

Une fois établie, chaque Mac envoie `Ecrans`, puis `Disposition` si sa disposition n'est pas automatique.

Vecteurs de test complets (clés, transcription, secret, clés dérivées, code, un enregistrement TCP et un
datagramme scellés) : `docs/octets-de-reference/vecteurs-crypto.txt`. Les signatures Ed25519 en sont exclues
(CryptoKit les rend non déterministes) : seule leur vérification compte.

## 6. Comportement de session

États de chaque Mac : **local**, **pilote(P)** (il envoie ses entrées à P), **piloté par(P)** (il injecte ce que P envoie).

1. Le Mac qui pilote franchit un bord vers P : il bloque et masque son curseur, envoie `Entree` (point d'entrée
   dans l'espace de P), puis des `Mouvement` (temps réel) et les autres événements (fiable). Il **supprime**
   localement tout ce qu'il envoie.
2. P passe en « piloté », poste un premier mouvement au point d'entrée (curseur visible même sans souris), puis
   poste chaque message **dès réception**, sans file d'attente ni lissage. Un `Mouvement` dont la séquence n'est pas
   plus récente que le dernier appliqué (comparaison 32 bits avec bouclage, RFC 1982) est ignoré.
3. Retour par un bord, bascule vers un autre Mac, panique : le pilote envoie `Sortie` (et `ToutRelacher` en cas de
   panique). P **relâche tout ce qu'il a injecté** : boutons, touches ordinaires, modificateurs, touches système.
4. **Relâchement au bon endroit** : une touche enfoncée sur un Mac est relâchée sur ce même Mac, même si la bascule a
   eu lieu entre l'appui et le relâchement.
5. **Pas de bascule** tant qu'un bouton ou une touche ordinaire est enfoncé (les modificateurs n'empêchent pas).
6. **Battement de cœur** : `Ping` toutes les 250 ms (UDP, sinon le trafic TCP suffit). Tout message reçu prouve que
   le lien vit. Au-delà de 0,75 s sans nouvelles : lien « dégradé ». Au-delà de **2 s** : chaque côté rend tout en
   local de lui-même (le piloté relâche tout sans avoir besoin du réseau) et ferme la connexion.
7. Veille, verrouillage, arrêt de l'app : `Sortie` (raison 2 ou 3) et relâchement complet.
8. **Raccourcis** (interceptés en premier, même pendant le pilotage, appui et relâchement supprimés) :
   ⌃⌥⌘L tout rendre en local ; ⌃⌥⌘1…9 aller au n-ième Mac (ordre gauche → droite de la disposition).
   Sur un Mac piloté, ⌃⌥⌘L relâche tout et envoie `Sortie` (panique) au pilote, qui reprend la main en local.
9. **Presse-papiers** : à chaque bascule et après chaque copie (⌘C/⌘X), le Mac compare son compteur de
   changements ; s'il a changé, il lit le texte et l'envoie à tous les pairs (offre puis morceaux de 32 Kio,
   4 Mio au plus). Un texte reçu est écrit et son empreinte retenue : il n'est jamais renvoyé (pas d'écho).

## 7. Évolutions

- Ajouter un champ en fin de charge ou un nouveau type de message : **mineure + 1** (les anciens l'ignorent).
- Changer la signification ou l'ordre d'un champ, la trame ou la poignée de main : **majeure + 1**.
- Toute modification met à jour ce document **et** les fichiers de référence (`SLIPWAY_REGENERER=1 swift test`).
