# Sécurité

Slipway peut taper au clavier et cliquer sur un autre Mac : la sécurité du lien est donc essentielle.

## Modèle
- Chaque Mac a une identité Ed25519, rangée dans le Trousseau (jamais dans un fichier ni un journal).
- Chaque connexion fait un échange X25519 éphémère ; tout passe ensuite par ChaCha20-Poly1305 avec compteurs
  (rejeu et altération rejetés), sur TCP comme sur UDP.
- Premier contact : le client s'engage sur sa clé avant de voir celle du serveur, puis un code à 6 chiffres dérivé
  de l'échange est affiché sur les deux Mac et doit être confirmé sur **les deux**. La clé du pair est ensuite épinglée.
- Avant la fin de l'appairage, aucun événement clavier, souris ou presse-papiers n'est accepté.
- Le presse-papiers n'est lu qu'après une copie (⌘C) ou un passage vers un autre Mac ; son contenu n'est jamais journalisé.
- Mises à jour : archives signées EdDSA (Sparkle), vérifiées avant extraction.

Détails : [docs/protocole.md](docs/protocole.md).

## Signaler une faille
Ouvrez un [avis de sécurité privé](https://github.com/AnthonyTrtre/slipway/security/advisories/new) sur GitHub
plutôt qu'un ticket public.
