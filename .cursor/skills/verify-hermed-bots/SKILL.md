---
name: verify-hermed-bots
description: Mandatory live checks for HermedBots, including Sparkle updates and the SSH alias connection. Use after an app change, a distribution change, or any update install.
---

# Verify HermedBots

Run these checks on the installed app, not only on unit tests. Feature maps live in `features/`.

## Mandatory after every Sparkle update

An update must replace the previous HermedBots bundle. It must not leave a second copy on disk.

After the installer finishes and the app has relaunched:

1. Count bundles whose `CFBundleIdentifier` is the identifier of the app under test: `com.hermedbots.HermedBots.updateproof` in the local `run` mode, the identifier read from the installed app in the `published` mode (`com.hermedbots.HermedBots`).
2. Combine Spotlight (`mdfind "kMDItemCFBundleIdentifier == '<identifier>'"`) with `path:` rows from `lsregister -dump` whose identifier matches.
3. Drop paths that no longer exist, and paths under the source and build folders of the pass (`SPARKLE_PROOF_BUILD_DIR`, colon separated): `dd`, `v<N>` and `v<N+1>` in the `run` mode, the extracted previous release in the `published` mode.
4. Require exactly one remaining copy, at the target version.
5. Fail when `mdfind` or `lsregister` is missing or exits nonzero. The output then holds a line `single-copy discovery-failed source=<tool>` and the proof line records `single-copy fail`.

Evidence is `scripts/sparkle-update-proof.sh`. The proof is a failure (nonzero) unless the `SPARKLE-PROOF*` line contains `single-copy pass`. `single-copy fail` is a failed verification.

See `features/sparkle-update.md`.

## Connexion

Lire `features/connection.md`.

L'utilisateur saisit un alias SSH. L'app résout tout le reste avec `/usr/bin/ssh -G <alias>` (config par défaut, `Include` compris). Le tunnel, `hermes profile list` et la lecture de `API_SERVER_KEY` passent par `/usr/bin/ssh` et le même alias. Pas de `-F /dev/null`, pas de `-i`, pas d'agent privé, pas de lecture de clé SSH dans le Trousseau.

Aucune saisie de clé API. Récupération figée : `hermes -p <profil> config get API_SERVER_KEY --raw`. Un profil n'utilise que sa propre clé, jamais celle de `default`. Échec sans clé : « Clé API introuvable sur l'hôte pour le profil … ». Clé détenue mais refusée : « La clé API est refusée pour le profil … ». Jamais la valeur.

Les tests du parser et du planificateur n'utilisent que des alias et des hôtes `.invalid`, des chemins fictifs, des sorties `ssh -G` simulées, et un ssh simulé pour la commande de clé. Les tests unitaires contiennent aussi des adresses de boucle locale, sans aucune connexion : l'argument `-L 127.0.0.1:<port>:127.0.0.1:8642` dans `SSHTunnelTests`, une config `hostname: "127.0.0.1"` port 1 dans `SystemSSHBackendTests` (le test ferme le backend avant `open`, aucun `ssh` ne démarre) et l'URL d'API `http://127.0.0.1:18642` dans `AppEnvironmentTests`.
