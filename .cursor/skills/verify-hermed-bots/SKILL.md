# verify-hermed-bots

Skill de vérification de Hermed Bots. Cartes d'écran dans `features/`.

Avant une PR qui touche un écran, lire la carte correspondante et y reporter les identifiants `hd.*` ainsi que le comportement observable.

## Connexion

Lire `features/connection.md`.

L'utilisateur saisit un alias SSH. L'app résout tout le reste avec `/usr/bin/ssh -G <alias>` (config par défaut, `Include` compris). Le tunnel et `hermes profile list` passent par `/usr/bin/ssh` et le même alias. Pas de `-F /dev/null`, pas de `-i`, pas d'agent privé, pas de lecture de clé SSH dans le Trousseau.

Les tests unitaires n'utilisent que des alias et des hôtes `.invalid`, des chemins fictifs, et des sorties `ssh -G` simulées.
