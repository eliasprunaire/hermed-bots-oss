---
style_gate: pass
name: verify-hermed-bots
description: "Vérifie l'app macOS native Hermed Bots (SwiftUI/AppKit) qui parle aux agents Hermes : pilotage XCUITest headless depuis le lanceur le planificateur du lanceur, Hermes jetable dans OrbStack ou faux serveur à fixtures, garde des chemins protégés, captures de référence, test quotidien de compatibilité. À utiliser pour toute recette, tout test de non-régression ou tout run quotidien de l'app Hermed Bots."
---

# verify-hermed-bots

Ce skill vérifie l'app macOS native Hermed Bots et son adaptateur Hermes.
Les fixtures viennent des relevés du spike (`fixtures/README.md`, `docs/spike/`).
Les passes API tournent contre `${HV_CONTAINER}` ou le faux serveur.
Les passes UI tournent uniquement dans la VM du lanceur.

Sources qui priment : PRD `version-finale-v2.md`, amendements A1–A12 (surtout A3, A5, A7, A8, A10, A11, A12) ; `runner-mac.md` ; `regles-workflow.md` règles 13 et 14.

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

## Règles de passe (non négociables)

1. **Périmètre Mac (A12)** : uniquement le conteneur dédié `${HV_CONTAINER}` et le dossier dédié `$HV_WORK`. Rien d'autre sur le Mac, jamais de push sur main, jamais ${HV_PROTECTED_HOST}.
2. **Chemins protégés** : `~/.hermes/hermes-agent` et `~/.local/bin/hermes` sont relevés (existence, mtime, hash) avant et après chaque passe par `hv-guard.sh`. Changement → arrêt, code 20. Présents avant la passe → refus, code 21. Toute cible contenant `${HV_PROTECTED_HOST}` → code 22.
3. **Secrets** : les lanes API lisent `HV_TEST_API_KEY`. La lane UI réelle lit les deux clés distinctes dans un fichier privé de test hors dépôt, décrit dans `features/vm-tunnel.md`. La VM les garde seulement pendant la connexion. Jamais dans un argument de commande, un log, une capture ni le chat. `hv-selftest.sh` vérifie qu'elle n'apparaît pas dans les preuves.
4. **Sondage des bords (même règle que verify-app-pilote)** : exécuter vraiment, puis sonder les limites : valeurs vides, négatives, inexistantes, invalides, très longues, doubles clics, coupure au mauvais moment. Une sonde qui plante est notée **FAIL (crash)** et les autres sondes continuent. Ne jamais affaiblir un parcours pour qu'il passe ; si une précondition manque, noter FAIL et la raison dans les `Gotchas` de la fonction.
5. **Coût (règle 14)** : chaque étape porte son modèle. Scripts = **aucun modèle**. Tri des logs et rédaction du rapport = **Haiku**. Jugement de vérification (lecture d'un xcresult ambigu, verdict PASS/FAIL d'une PR) = **Sonnet ou Codex (effort medium)**, d'un autre fournisseur que l'auteur. Jamais Opus pour ce skill.

## Launch

Modèle : aucun.

Préalable unique, par l'auteur de la PR ou la CI (pas par le vérificateur) :

```bash
xcodebuild build-for-testing -scheme HermedBots -destination 'platform=macOS' \
  -derivedDataPath "$HV_WORK/dd"          # produit $HV_WORK/dd/Build/Products/*.xctestrun
export HV_XCTESTRUN=$(ls "$HV_WORK"/dd/Build/Products/*.xctestrun | head -1)
```

Environnement Hermes (au choix) :

```bash
# A. Hermes jetable (préféré, A8). Image construite depuis orb/Dockerfile (voir docs/spike/README.md).
scripts/hv-hermes-env.sh up orb   # image ${HV_HERMES_IMAGE}
# B. Faux serveur à fixtures (sans le relais local, CI, Linux).
HV_FAKE_VERSION=current HV_FAKE_MODE=normal scripts/hv-hermes-env.sh up fake
```

- Prêt = `scripts/hv-hermes-env.sh doctor <mode>` répond (mode orb : `readiness: ok` sur `GET /health/detailed` ; mode fake : `/_hv/ready`) **et** `hv-bot-a`, `hv-bot-b` répondent par le préfixe `/p/<profil>/` (mode orb).
- Mode orb : `docker run` **sans aucun `-v`/`--mount`**, label `hv.owner=verify-hermed-bots`, port publié seulement sur la boucle locale `${HV_PORT}` ; Hermes écoute dans le conteneur sur `${HV_CONTAINER_PORT}` (`API_SERVER_ENABLED=true`, défini par l'image) et docker publie ce port sur `127.0.0.1:${HV_PORT}` de l'hôte : ni socat ni tunnel. Le script refuse (code 31) tout montage contenant `/.hermes` ou `/.local/bin`. Ne **pas** utiliser une « machine » du relais local : elles montent le dossier utilisateur de l'hôte par défaut.
- Amorçage par l'image (`orb/hv-start.sh`) : les neuf profils actifs du PRD, `hv-bot-a`, `hv-bot-b`, et le profil inactif `hv-old` (marqueur `gateway.parked`). `hv-start.sh` n'écrit `API_SERVER_KEY` dans un `.env` que si la ligne y manque, ce qui conserve les clés distinctes par profil. On recrée le conteneur avec le volume `${HV_HERMES_VOLUME}` et `--env-file $HV_WORK/secrets/hv-test.env`, sans afficher de secret.
- L'app est lancée **par XCUITest** (`XCUIApplication().launch()`) avec `launchEnvironment` : `HV_TEST_MODE=1`, `HV_API_URL`, `HV_SHOTS`. Voir « Mode test sans Trousseau ».

Teardown : `scripts/hv-hermes-env.sh down <mode>` (ne détruit que le conteneur à notre label ou le PID du faux serveur que nous avons lancé).

Point d'entrée unique (headless, lanceur) :

```bash
timeout 3600 python3 .cursor/skills/verify-hermed-bots/scripts/hv-vm-ui.py  # passe UI réelle dans la VM
scripts/hv-run.sh api orb                         # contrats seuls contre l'OrbStack
scripts/hv-run.sh compat                          # 3 tests A7 côté API
scripts/hv-run.sh daily orb                       # test quotidien A11
```

| Code | Sens |
|---|---|
| 0 | PASS |
| 2 | usage |
| 3 | `${HV_RUNNER_DIR}/PAUSE` présent : rien lancé |
| 4 | verrou pris (`${HV_RUNNER_DIR}/.lock` hors lanceur, ou `$HV_WORK/.hv-lock`) |
| 10 | au moins un test/contrat FAIL |
| 11 | écart visuel > tolérance |
| 12 | référence visuelle manquante |
| 13 | ImageMagick absent, en erreur ou métrique invalide |
| 14 | connexion sortante interdite |
| 15 | capture annoncée par `HV-SHOT` absente du xcresult, ou aucune capture |
| 20 | **chemin protégé modifié — arrêt** |
| 21 | chemin protégé présent avant la passe |
| 22 | cible ${HV_PROTECTED_HOST} refusée |
| 30–34 | environnement Hermes (OrbStack absent, montage interdit, secret absent, pas prêt) |
| 40 | xcodebuild ou `HV_XCTESTRUN` absent |

Aucun prompt interactif. Le verrou distant `lock.json` (owner=cloud) est géré par `runner.sh` : quand owner=cloud, le lanceur n'appelle pas ce skill.

### Exécution en VM (lanceur Mac, depuis le 2026-10-19)

Modèle : aucun.

La lane réelle utilise [features/vm-tunnel.md](features/vm-tunnel.md).
Depuis la racine du dépôt, lancer `timeout 3600 python3 .cursor/skills/verify-hermed-bots/scripts/hv-vm-ui.py`.
Le script appelle `vm.sh exec env HV_UI_BACKEND=orb bash .cursor/skills/verify-hermed-bots/scripts/hv-run.sh ui fake`, puis ouvre la redirection SSH inverse.
`HV_UI_BACKEND=fake` choisit explicitement la suite de fixtures via `vm.sh exec`.
L'appel direct à `zsh ${HV_RUNNER_DIR}/vm.sh ui fake` conserve la suite de fixtures, sans tunnel ni clés réelles.

Sous le lanceur, les passes UI ne tournent plus sur l'écran du Mac. Les agents (auteur, correctif, vérificateur) passent par le module du lanceur, depuis la racine du dépôt :

```bash
python3 .cursor/skills/verify-hermed-bots/scripts/hv-vm-ui.py  # profils réels, tunnel géré
zsh ${HV_RUNNER_DIR}/vm.sh exec <script> [args]    # script de lane du dépôt (xcodebuild test-without-building -only-testing…)
```

- **VM** : VM de test macOS provisionnée selon la doc interne, copie jetable clonée depuis `${HV_UI_GOLDEN}`, lancée sans interface graphique, puis arrêtée et supprimée après la passe. Une seule VM de test à la fois.
- **Dans la VM** : session graphique de test non administrateur, ouverte automatiquement (XCUITest l'exige). Aucun secret durable dans la VM (ni jeton, ni clé API, ni webhook).
- **Réseau** : filtrage sortant actif dès le démarrage (doc interne). Tout est rejeté sauf le SSH entrant depuis l'hôte et le DHCP ; la boucle locale reste libre pour le faux serveur. Le module vérifie ce filtrage avant chaque passe. S'il est inactif, la passe reste en attente.
- **Déroulé** : archive de l'arbre de travail (`git ls-files`, modifications non commitées comprises), `build-for-testing` puis `hv-run.sh ui fake` dans la VM, preuves rapatriées dans `$HV_WORK/evidence/ui-<horodatage>-vm/` (captures dans `shots/`), journal du module dans `$HV_WORK/evidence/vmui-<horodatage>/`.
- **Jamais sur l'hôte** : aucun repli sur le Mac. Si l'outil de VM, `${HV_UI_GOLDEN}` ou la session graphique manquent, si la VM ne démarre pas, n'obtient pas d'adresse, si SSH échoue, est coupé ou dépasse `${HV_UI_TIMEOUT}`, si le filtrage est inactif, la passe UI est **en attente** : code 6, ligne `HV-UI SAUTÉE`. Ce n'est ni un FAIL ni un BLOCKED. L'attente est notée dans le journal du lanceur. Si la VM reste indisponible au-delà de `${HV_UI_ALERT_AFTER}`, une seule alerte part par le notificateur du lanceur.
- **Chemins protégés** : `hv-guard.sh` relève l'hôte avant et après chaque passe, quel que soit le chemin. Changement → code 20, `${HV_RUNNER_DIR}/PAUSE-<dépôt>` posé, arrêt. `hv-run.sh` refait sa propre garde dans la VM.
- **Trace** : dernière ligne `HV-UI chemin=vm|attente rc=… durée=… preuves=…` (à citer dans Verification et dans le verdict), une ligne par passe dans `${HV_RUNNER_DIR}/logs/runner-<date>.log` et `state/<dépôt>/ui-runs.log`, et un résumé par rôle à la fin de chaque agent.
- **Interdit sur l'hôte** pendant une passe d'agent : `hv-run.sh ui`, `xcodebuild test` ou `test-without-building` en direct, et tout pilotage de l'écran, du clavier ou de la souris (osascript, System Events, JXA, cliclick).
- **HV-PERF en VM** : la médiane cold-launch mesurée en VM (1 474 à 1 610 ms selon les passes) est au niveau de l'hôte (1 612 ms). Le budget de 2 000 ms reste un garde-fou, mais la VM partage le CPU et le disque avec l'hôte : comparer de préférence VM contre VM. Les valeurs de référence absolues restent mesurées sur l'hôte.

Codes propres au module (en plus de ceux de `hv-run.sh`, qu'il renvoie tels quels) : 2 usage, 3 PAUSE, 20 chemin protégé modifié sur l'hôte, 22 cible refusée par `hv-guard.sh target`, 6 passe UI en attente (VM indisponible), 40 `build-for-testing` en échec.

Les tests d'interface sont INTERDITS sur l'hôte : ni `hv-run.sh ui`, ni `xcodebuild test` ou `test-without-building`, ni lancement de l'app, ni pilotage de l'écran, du clavier ou de la souris du Mac. Tout passe par `vm.sh`. Une passe `HV-UI SAUTÉE` n'est jamais rejouée sur l'hôte.

Pièges de la VM (doc interne) :

- **Identité réseau** : le réseau de l'invité est lié à l'identité de l'image `${HV_UI_GOLDEN}` (`${HV_VM_MAC}`). Une copie avec une identité neuve démarre, mais reste injoignable. Une seule copie tourne à la fois.
- **Python** : dans la VM, un interpréteur hors du PATH système peut attendre le DNS bloqué par le filtrage. Le faux serveur rate alors son délai (code 34). Le module met le PATH système en tête.
- **Session graphique initiale** : un assistant de configuration peut rester lancé sans fenêtre. Ne pas le tuer : sa mort casse la session Aqua, et xcodebuild ne joint plus le runner de tests (code 15).
- **Script distant** : il est copié dans la VM, puis lancé avec stdin=/dev/null. Un `bash -s` alimenté par le tube ssh n'est pas utilisé.

## Classement dry-run

Modèle : aucun.

Le script `scripts/hv-classify.js --dry-run` lit la Feature Map versionnée `features/map.v1.json` (fonctionnalités et globs de code) et écrit un JSON conforme à `schema/dry-run.v1.json` :

| Champ | Valeurs |
|---|---|
| `path` | `fast` (aucun fichier UI et aucun label `needs-ui`), `ui` (au moins un fichier UI, label `needs-ui`, ou Feature Map absente/illisible/invalide), `fast_suspended` (UI requise mais VM UI indisponible) |
| `needs_ui` | booléen |
| `features` | identifiants de la carte qui matchent |
| `mode` | `light` si `--same-patch-id` et `--pr-pass` ; sinon `full`. Le label `needs-full-verify` force `full`. |
| `ui_plan` | `none` si `path=fast` ; sinon `ui-core` ou `ui-full` (voir « Plans de test UI ») |
| `ok` | booléen |
| `errors` | liste de chaînes |

VM UI indisponible : `--ui-unavailable`, ou `HV_UI_UNAVAILABLE=1`, ou `HV_UI_AVAILABLE=0`.

Le label `needs-ui` force `path=ui` (`ui-full` en cas de doute). Il ne change pas `mode`. Le label `needs-full-verify` reste inchangé.

Sans Feature Map, ou carte illisible ou invalide : code de sortie ≠ 0, `ok=false`, `path=ui`, `ui_plan=ui-full`, erreur `feature map absente` / `illisible` / `invalide`. Jamais `path=fast`.

### Plans de test UI (`ui-core` / `ui-full`)

Les plans versionnés `TestPlans/UICore.xctestplan` et `TestPlans/UIFull.xctestplan` (scheme `HermedBots`, jamais de parallélisme) découpent la passe XCUITest :

| Plan | Classes |
|---|---|
| `ui-core` | `SixActions`, `LaunchTests`, `HD12Video` |
| `ui-full` | toute la cible UI (sondes de perf exclues) et la cible `HermedBotsTests` |

`hv-classify.js` choisit `ui_plan` d’après la Feature Map (`ui_plan` sur chaque glob ; première entrée qui définit `ui_plan` pour le fichier) et ces règles, **en cas de doute : `ui-full`** :

- **`ui-full`** si un fichier Swift d’interface est modifié (`HermedBots/**/*.swift` hors `Secrets/`), ou si une zone de captures / profils / compat visuelle est touchée (`Piste1Shots`, `DesignShots`, `ProfileKeys`, `Compat`, `VersionProfiles`, `baselines/**`, globs `ui_plan: "full"`).
- **`ui-core`** si l’UI est requise sans ces déclencheurs (tests cœur, scripts de lane, etc.).
- **`none`** si `needs_ui` est faux.

Exporter `HV_UI_PLAN` depuis `ui_plan` avant `hv-run.sh ui` / `hv-vm-ui.py`. Défaut `ui-full`. Avec `test-without-building`, `ui-core` ajoute `-only-testing` pour les trois classes (le `.xctestplan` sert à `xcodebuild test -scheme HermedBots -testPlan UICore`).

```bash
node .cursor/skills/verify-hermed-bots/scripts/hv-classify.js --dry-run --files-from liste.txt
node .cursor/skills/verify-hermed-bots/scripts/hv-classify.js doctor
```

## Doctor

Modèle : aucun. Lecture seule ; à lancer dès que quelque chose cloche.

```bash
scripts/hv-guard.sh snapshot "$HV_WORK/doctor.txt" && cat "$HV_WORK/doctor.txt"   # chemins protégés absents ?
scripts/hv-hermes-env.sh doctor orb      # conteneur à notre label, en marche, sans montage, santé API
scripts/hv-hermes-env.sh doctor fake
xcrun xcodebuild -version; test -f "$HV_XCTESTRUN" && echo xctestrun OK
ls ${HV_RUNNER_DIR}/PAUSE ${HV_RUNNER_DIR}/.lock "$HV_WORK/.hv-lock" 2>/dev/null   # rien ne doit sortir
node .cursor/skills/verify-hermed-bots/scripts/hv-classify.js doctor   # SKILL.md, Feature Map v1, schéma dry-run v1
```

Vaut la peine d'être piloté si : chemins protégés absents, environnement prêt avec version lue, `.xctestrun` présent, aucune pause ni verrou, session graphique de test ouverte dans la VM. Le module vérifie cette précondition avant XCUITest.

## Drive

Modèle : aucun pour l'exécution ; Sonnet/Codex seulement pour juger un résultat ambigu.

**Harnais principal : XCUITest**, `xcodebuild test-without-building -xctestrun "$HV_XCTESTRUN" -destination 'platform=macOS' -resultBundlePath <evd>/result.xcresult`, lancé par `hv-run.sh ui`. `HV_UI_PLAN=ui-core|ui-full` (défaut `ui-full`, voir « Plans de test UI ») filtre les classes. Les variables `TEST_RUNNER_HV_*` sont transmises au runner de tests sans le préfixe. Permissions requises une fois (manuel, utilisateur présent) : Accessibilité et Automatisation pour `Xcode Helper`/`xctest` dans Réglages Système.

Une VM indisponible laisse la passe UI en attente. Aucun pilotage de l'hôte ne sert de repli.

**Sélecteurs : uniquement des `accessibilityIdentifier` stables.** Jamais de libellé traduit, de coordonnée, d'index ni d'ordre de tabulation.

Convention : `hd.<écran>.<élément>[.<id-dynamique>]`, minuscules, kebab-case, `<id-dynamique>` = identifiant Hermes stable (profil, session, approbation), jamais un index d'affichage. Défini une seule fois dans `AccessibilityID.swift` (enum partagé entre app et cible de tests).

Identifiants que l'app **doit** exposer (la PR qui ajoute l'écran sans eux est FAIL) :

| Identifiant | Élément |
|---|---|
| `hd.bots.list` | liste des bots (barre latérale) |
| `hd.bots.row.<profileId>` | ligne d'un bot |
| `hd.bots.row.<profileId>.name` / `.model` | nom et modèle affichés |
| `hd.bots.row.<profileId>.threads` | identifiant conservé ; plus de groupe de fils dans la barre latérale |
| `hd.threads.row.<sessionId>` | identifiant conservé ; plus de ligne de session dans la barre latérale |
| `hd.status.compat` | mention discrète de compatibilité dans le pied |
| `hd.conversation.opening` | pastille « Connexion… » à l'ouverture d'un bot |
| `hd.conversation.compacted` | bandeau de compaction du contexte |
| `hd.about.compat` | détail de compatibilité dans Réglages → À propos |
| `hd.conversation.view` | zone de conversation |
| `hd.conversation.message.<index-serveur>` | message (index fourni par Hermes, pas d'affichage) |
| `hd.conversation.state` | état terminal du tour (terminé, échoué, annulé, interrompu) |
| `hd.composer.input` | champ de saisie |
| `hd.composer.send` | bouton Envoyer |
| `hd.session.new` | bouton Nouvelle session (`/new`) |
| `hd.model.picker` | sélecteur de modèle (`/model`) |
| `hd.model.option.<modelId>` | option du sélecteur |
| `hd.approval.sheet` | feuille d'approbation |
| `hd.approval.tool` | nom de l'outil demandé |
| `hd.approval.params` | paramètres de l'outil |
| `hd.approval.yes` / `hd.approval.no` | Approuver / Refuser |
| `hd.approval.status` | ce que la feuille dit de la réponse : le bot attend, la réponse est partie, ou elle attend le retour de la liaison |
| `hd.approval.cut` | marqueur des paramètres que la feuille ne montre pas en entier (coupure, caractères de contrôle écrits `\u{…}`) |
| `hd.approval.disabled` | message de `approve` désactivée : la demande reste affichée, Oui et Non sont grisés |
| `hd.approval.kill-switch` | renvoi au kill switch quand la réponse est désactivée |
| `hd.tool.current` | ligne « outil en cours » |
| `hd.banner.degraded` | bandeau mode dégradé (A10) |
| `hd.banner.degraded.feature.<contrat>` | fonction désactivée et son message |
| `hd.banner.error` | bandeau d'erreur (API injoignable, lente, 401) |
| `hd.banner.error.retry` | bouton Réessayer |
| `hd.status.version` | version Hermes lue (information seule, A7) |

### Mode test sans Trousseau (A5)

- `HV_TEST_MODE=1` dans `launchEnvironment` fait injecter un `SecretStore` en mémoire (protocole unique `SecretStore`, implémentations `KeychainSecretStore` et `InMemorySecretStore`). En mode test, l'app lit la clé dans `HV_TEST_API_KEY` (passée par `TEST_RUNNER_HV_TEST_API_KEY`) et **n'appelle jamais** `SecItem*`.
- Preuve que le Trousseau n'est pas touché : test unitaire avec un `KeychainSecretStore` espion qui échoue s'il est appelé, plus `log show --predicate 'subsystem == "com.apple.securityd"' --last 5m | grep HermedBots` vide après la passe (contrôle manuel distinct des tests du magasin en mémoire).
- Le mode test ne doit être actif que dans les builds Debug/Test (`#if DEBUG`) ; une Release qui l'accepte est un FAIL.
- Le Trousseau réel au premier lancement reste **manuel** (A3).

### Tests automatiques (A3, A7)

Modèle : aucun.

| Test | Feature map | Comment |
|---|---|---|
| `SixActions.testListBots` | `features/bot-list.md` | liste = profils actifs ; `hv-old` absent ; pas de fils sous le bot |
| `SixActions.testConversation` | `features/conversation.md` | envoi, réponse, état terminal |
| `SixActions.testModelSwitch` | `features/model-switch.md` | `/model` sur la session ouverte |
| `SixActions.testApprovalYes` / `testApprovalNo` | `features/approval.md` | outil et paramètres visibles avant réponse |
| `SixActions.testCurrentTool` | `features/approval.md` | `hd.tool.current` pendant l'appel |
| `SixActions.testResumeAfterSleep` | `features/resume-and-errors.md` | veille simulée : `POST /_hv/cut` (fake) ou `docker network disconnect` (orb), puis événement injecté ; pas de double envoi (`/_hv/log`) |
| `Errors.testApiUnreachable` / `testApiSlow` | `features/resume-and-errors.md` | `HV_FAKE_MODE=down` / `slow` : bandeau d'erreur propre, UI jamais figée |
| `Events.testUnknownEventIgnored` | `features/resume-and-errors.md` | `hv.unknown_future_event` dans le flux : aucun plantage, tour complet |
| `Compat.testRecentVersion` | `features/compat-degraded.md` | fixture `previous`/`current` |
| `Compat.testFieldsAddedRemoved` | `features/compat-degraded.md` | `HV_FAKE_MODE=fields` : valeurs par défaut, aucun plantage |
| `Compat.testRouteRemoved` | `features/compat-degraded.md` | `HV_FAKE_MODE=drop-route HV_DROP=set_model` : seul le sélecteur de modèle est désactivé, `hd.banner.degraded.feature.set_model` clair, le reste marche |
| `Network.noOutbound` | — | `hv-netwatch.sh` pendant la passe : seule la boucle locale `${HV_PORT}` (test) ; en prod seul le tunnel SSH |

Côté API seule (sans app) : `scripts/hv-contract-check.py` vérifie chaque contrat de la fixture (la liste des profils par `hermes profile list` via `--profile-cmd`) et sonde les bords (message vide, id inexistant, id négatif, JSON invalide, sans clé) en mode fake et en mode orb. En mode orb, `hv-run.sh api orb` lance ensuite `scripts/hv-spike-probe.py` (scénarios S1 à S7 du spike : coupure réseau, annulation d'un outil).

**À la main (A3)** : jugement visuel final, veille réelle du Mac (fermer le capot pendant un tour long et pendant une approbation en attente), Trousseau au premier lancement. Utilisateur présent ; consigner le résultat dans `<evd>/manuel.md`.

## Evidence

Modèle : aucun pour la collecte ; Haiku pour résumer.

Dossier : `$HV_WORK/evidence/<mode>-<AAAAMMJJ-HHMMSS>/` (heure de Paris), hors de tout ce que le nettoyage supprime.

| Fichier | Contenu |
|---|---|
| `run.log` | journal complet horodaté (Paris) |
| `guard-before.txt`, `guard-after.txt` | relevé des chemins protégés |
| `env.json`, `env.log`, `fake-server.log` | environnement Hermes utilisé |
| `contracts.json`, `compat-*.json` | PASS/FAIL par contrat et par sonde |
| `result.xcresult`, `xcodebuild.log` | résultat XCUITest (captures d'échec incluses) |
| `shots/<écran>.png`, `diffs/<écran>.png` | captures et différences |
| `reference-shots/<écran>.png` | captures comparées, sans les images vidéo intermédiaires |
| `net.txt`, `net.txt.nettop` | connexions observées |
| `rapport-quotidien.md`, `ALERTE` | test quotidien |

Standards de preuve : chemin utilisateur réel (clics XCUITest, pas de setters internes) ; capturer l'action **et** l'état qui en résulte ; vérifier l'effet de bord côté Hermes (`/_hv/log` : un seul `POST` par message ; session `/new` visible dans `list_sessions`) ; les routes `/_hv/*` sont des outils de test du faux serveur, jamais une preuve fonctionnelle.

### Captures de référence

Les références versionnées et leur régénération suivent le [README des références](baselines/README.md).

- Chaque test appelle `HVShot.capture("<écran>")` (helper XCUITest : `XCUIScreen.main.screenshot()` ou `app.windows.firstMatch.screenshot()`, fenêtre 1280×800, apparence claire, `-AppleLanguages (fr)`), joint l'image au xcresult et écrit `HV-SHOT <écran>` dans la sortie. Le runner XCUITest est sandboxé : il n'écrit pas dans `$HV_SHOTS`. `hv-run.sh ui` exporte les pièces jointes vers `shots/<écran>.png` (`hv-shotdiff.sh --export`) et échoue (code 15) si une capture annoncée manque.
- Écrans : `bots`, `conversation`, `model-picker`, `approval`, `tool-current`, `degraded`, `error`, `threads`.
- Comparaison : `scripts/hv-shotdiff.sh <evd>/reference-shots baselines <evd>/diffs <tolérance>` (fraction de pixels différents, fuzz 5 %). La lane orb utilise 0.03 (3 %). Les lanes fake et les autres modes utilisent 0.02 (2 %). `hv-run.sh` choisit cette valeur selon `HV_UI_BACKEND` ou, à défaut, le mode d'environnement. Le code 11 fait échouer la passe.
- Promotion d'une référence : **humaine seulement**, `scripts/hv-shotdiff.sh --bless <evd>/reference-shots baselines`, dans une PR dédiée. Le jugement visuel final reste manuel.

### Test quotidien (A11) — 13 h 00, heure de Paris

Modèle : aucun pour le run ; Haiku pour la transmission à Dev Lead.

- Créneau fixe 13 h 00 Paris (utilisateur présent pour les approbations). Déclenché par le lanceur : `HV_UNDER_RUNNER=1 scripts/hv-run.sh daily orb` (repli `fake` si OrbStack absent, à signaler comme tel dans le rapport).
- `daily` lance les contrats API et les six actions sur les neuf profils du PRD.
- Les actions couvrent la liste, la nouvelle session, le modèle, la conversation, les deux réponses d'approbation et l'outil en cours.
- Le netwatch observe le contrôleur API pendant la passe. Il ne prouve pas le réseau de l'app.
- Les trois cas de robustesse utilisent les fixtures précédente, champs modifiés et route retirée.
- Une route retirée attend uniquement `set_model` en 404. Tout autre échec reste un échec.
- `HV_USER_PRESENT=0` écrit `not run` avec sa cause, sans résultat de contrat ni alerte.
- Le mode `orb` se replie sur `fake` lorsque les commandes ou le service Docker manquent.
- Le rapport donne l'environnement demandé, l'environnement exécuté et la cause du repli.
- `fake` génère une clé éphémère en mémoire lorsque le lanceur n'en fournit pas.
- Rapport `rapport-quotidien.md` : date et heure de Paris, version Hermes, résultat par contrat, écarts, durée, garde et code de sortie.
- Les preuves restent dans un dossier unique par passe. Le verrou couvre les contrats et la robustesse.
- La passe d'acceptation UI reste distincte et passe par `hv-vm-ui.py`, qui appelle le lanceur VM.
- Aucune routine n'est créée. Manager et dr eggbot portent sa création après validation du PRD.
- Alerte utilisateur **uniquement** si FAIL ou chemin protégé modifié (fichier `ALERTE` présent). Sinon rapport à Dev Lead seulement.

## Cleanup

Modèle : aucun.

```bash
scripts/hv-hermes-env.sh down orb    # docker rm -f -v du seul conteneur label hv.owner=verify-hermed-bots
scripts/hv-hermes-env.sh down fake   # kill du PID enregistré, pas par nom
```

`hv-run.sh` le fait seul (piège de fin), refait le contrôle des chemins protégés **après** nettoyage, puis libère `$HV_WORK/.hv-lock`. Jamais de `pkill` par nom, jamais de suppression dans `$HV_WORK/evidence`. L'app lancée par XCUITest est terminée par XCUITest. Si `.hv-lock` reste après un crash : vérifier qu'aucun `hv-run.sh` ne tourne, puis `rmdir "$HV_WORK/.hv-lock"`.

## Helpers

Tous dans `scripts/`, exécutables, compatibles bash 3.2 (macOS) et Linux, shellcheck propre.

| Script | Rôle | Invocation |
|---|---|---|
| `hv-vm-ui.py` | tunnel VM vers le conteneur existant, profils et clés de test | `python3 .cursor/skills/verify-hermed-bots/scripts/hv-vm-ui.py` |
| `hv-run.sh` | point d'entrée unique, codes de sortie, preuves | `HV_UNDER_RUNNER=1 scripts/hv-run.sh {api\|ui\|daily\|compat} [orb\|fake]` |
| `hv-guard.sh` | chemins protégés, refus ${HV_PROTECTED_HOST} | `scripts/hv-guard.sh snapshot f.txt` ; `scripts/hv-guard.sh check f.txt` ; `scripts/hv-guard.sh target <hôte>` |
| `hv-hermes-env.sh` | Hermes OrbStack jetable ou faux serveur | `scripts/hv-hermes-env.sh {up\|doctor\|down} {orb\|fake}` |
| `hv-fake-hermes.py` | faux serveur à fixtures (A10), `/_hv/config` et `/_hv/reset` | `python3 scripts/hv-fake-hermes.py --port "$HV_PORT" --version current --mode drop-route` |
| `hv-spike-probe.py` | formes observées S1 à S7 (orb) | `python3 scripts/hv-spike-probe.py --url "http://127.0.0.1:${HV_PORT}" --out r.json` |
| `hv-contract-check.py` | contrats + sondes de bord ; `--acceptance` (daily) | `python3 scripts/hv-contract-check.py --url "http://127.0.0.1:${HV_PORT}" --fixture fixtures/hermes-current/contract.json --out r.json` |
| `hv-shotdiff.sh` | comparaison de captures | `scripts/hv-shotdiff.sh shots baselines diffs 0.03` (orb) ou `0.02` (fake et autres) |
| `hv-netwatch.sh` | connexions sortantes (lsof/nettop) | `scripts/hv-netwatch.sh <pid> 30 net.txt "$HV_PORT"` |
| `hv-selftest.sh` | auto-tests des scripts | `scripts/hv-selftest.sh` |
| `hv-start-env-key.sh` | `.env` au premier volume, clé distincte conservée, chmod 600 | `scripts/hv-start-env-key.sh` |
| `hv-daily-lanes.py` | dix lanes CLI et mesures HD-16, aucune UI | `python3 scripts/hv-daily-lanes.py` |
| `hv-classify.js` | classement dry-run JSON v1 (fast / ui / fast_suspended, `ui_plan`) | `node scripts/hv-classify.js --dry-run --files a,b` ; `node scripts/hv-classify.js doctor` |

## Preuves HD-16 du 21 octobre 2026

Les preuves de cette passe sont dans `evidence/hd16/`.

- `hv-selftest.sh` a tourné dans la VM via `vm.sh exec`. Le journal `vm-selftest.log` contient les résultats.
- `npm-test.log` et `npm-lint.log` donnent les contrôles du dépôt.
- `live-results.json` conserve les dix lanes CLI, les durées et les empreintes des scripts exécutés.
- `daily orb` a passé les contrats et les 54 actions sur les neuf profils contre la version Hermes relevée.
- `daily fake` passe au head. Le trunk échoue sur les champs de santé omis par son faux serveur.
- Le budget relatif fake est dépassé. La baseline trunk échoue. Aucun gain de performance n'est revendiqué.
- Le repli a été testé avec un socket Docker indisponible. Une machine extérieure active empêchait l'arrêt global d'OrbStack dans le périmètre.
- `vm-ui.log` donne la passe UI réelle. Les tests ignorés et leurs causes figurent dans `ui/xcode-summary.log`.
- Les captures sont exportées. La comparaison aux références affiche `MISSING`, car `baselines/` est vide.

## Preuves et reste à prouver

Prouvé sur le Mac (2026-10-18), sur la version `/bin/bash` 3.2.57 pour le selftest :

- `hv-selftest.sh` : 45 PASS, 0 FAIL, code 0. Le HOME est temporaire ; le test couvre la garde, les modes du faux serveur, la PAUSE, le verrou, le rapport quotidien et l'absence du secret dans les preuves.
- `shellcheck` 0.11 propre sur `scripts/*.sh`, `bash -n` propre, syntaxe des trois scripts `.py` contrôlée par `compile()`.
- Mode orb (version Hermes relevée, image `${HV_HERMES_IMAGE}`) : `up`, `doctor` (aucun montage hôte, `readiness=ok`, `hv-bot-a` et `hv-bot-b` répondent par `/p/<profil>/`), `down`. Passe live, journal dans `docs/spike/`.
- Sondes S1 à S7 PASS dans la passe live. S1 à S6 sont exigées par #6. S7 reste jugée sous #9.
- Coupure réseau réelle de 6 s pendant un tour : connexion refusée, reprise par `Last-Event-ID`, un seul tour.
- `hv-netwatch.sh` : `NET OK`, seule la connexion vers la boucle locale `${HV_PORT}` est vue (sortie `lsof`).
- `hv-guard.sh` : snapshot et check sur macOS, chemins protégés inchangés, `target ${HV_PROTECTED_HOST}` renvoie 22.

Source des réponses et des limites : `docs/spike/README.md`, sections « Items » et « Not observed ».

Reste à prouver :

- Les contrôles manuels du Trousseau réel et de la veille physique restent distincts des passes XCUITest dans la VM.
- La sortie `nettop` de `hv-netwatch.sh` : seule la sortie `lsof` figure dans la passe live.
- L'intégration avec `runner.sh` : les agents du lanceur appellent `${HV_RUNNER_DIR}/vm.sh` (section « Exécution en VM »). Le canal de demande de lane depuis le cloud reste à décider (`docs/spike/README.md`, « Cloud lane worker to Mac lane »).
- Le tunnel VM vers le conteneur existant passe par `hv-vm-ui.py`, documenté dans `features/vm-tunnel.md`. Les anciennes lanes de fixtures restent distinctes.
- Les réponses non observées : `POST /v1/chat/completions`, `POST /v1/responses`, le 409 `permission_denied`, `resolve-unknown`, une coupure de plus de six secondes, l'option de modèle s2.
