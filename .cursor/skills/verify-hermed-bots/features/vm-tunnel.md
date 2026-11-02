# Lane d'interface réelle dans la VM

La passe UI réelle tourne seulement dans la VM jetable du lanceur. L'hôte n'ouvre pas l'app, ne lance pas `hv-run.sh ui` et ne pilote ni l'écran, ni le clavier, ni la souris. Le tunnel inverse relie la VM au conteneur de test `hv-hermes-test` déjà présent sur l'hôte.

Point d'entrée : `python3 .cursor/skills/verify-hermed-bots/scripts/hv-vm-ui.py`.

## Sub-features

- `vm-ui-host` : depuis l'hôte, le script appelle `${HV_RUNNER_DIR}/vm.sh exec` puis ouvre la redirection SSH inverse.
- `vm-ui-guest` : dans la VM, `hv-run.sh ui` avec `HV_UI_BACKEND=orb` appelle `hv-vm-ui.py guest <evidence> <xctestrun>` (hv-run.sh, ligne 145).
- `vm-ui-fake` : `HV_UI_BACKEND=fake` via `vm.sh exec` garde la suite de fixtures, sans tunnel ni clés réelles.
- `vm-ui-live` : `LiveTunnel/testRealTestProfilesThroughTheVMTunnel` exige le tunnel et les deux clés de test.

## How to get to it (user POV)

L'utilisateur n'ouvre pas cette lane. L'auteur ou le vérificateur, depuis la racine du dépôt :

```bash
timeout 3600 python3 .cursor/skills/verify-hermed-bots/scripts/hv-vm-ui.py
```

`HV_UI_BACKEND=fake` choisit la suite de fixtures :

```bash
zsh ${HV_RUNNER_DIR}/vm.sh exec env HV_UI_BACKEND=fake \
  bash .cursor/skills/verify-hermed-bots/scripts/hv-run.sh ui fake
```

L'appel `zsh ${HV_RUNNER_DIR}/vm.sh ui fake` conserve aussi la suite de fixtures, sans tunnel ni clés réelles.

## Driving it

### Hôte

1. Refuser si `${HV_RUNNER_DIR}/PAUSE` est présent (code 3).
2. Contrôler la cible avec `hv-guard.sh target` (code 22 si elle contient `${HV_PROTECTED_HOST}`).
3. Si `vm.sh`, la copie maître, `tart` ou la session `hvtest` manquent, si la VM n'obtient pas d'adresse, si SSH échoue ou dépasse 45 min, ou si pf est inactif : ligne `HV-UI SAUTÉE`, code 6. Ce n'est ni un FAIL ni un BLOCKED. Aucun repli sur l'hôte.
4. Archiver l'arbre de travail (`git ls-files`, modifications non commitées comprises), puis `xcodebuild build-for-testing -scheme HermedBots -destination 'platform=macOS'` dans la VM. Échec → code 40.
5. Lire les deux clés distinctes dans le fichier privé hors dépôt `$HV_WORK/secrets/hv-ui-keys.json` (`hv-bot-a` et `hv-bot-b`). Jamais en argument de commande, jamais dans un log, une capture ou le chat. La VM les garde seulement pendant la connexion.
6. Ouvrir la redirection SSH inverse : le port publié du conteneur sur l'hôte (`127.0.0.1:${HV_PORT:-18642}`) devient `127.0.0.1:${HV_PORT:-18642}` dans la VM. Forme : `ssh -N -T -o ExitOnForwardFailure=yes -R 127.0.0.1:${HV_PORT:-18642}:127.0.0.1:${HV_PORT:-18642}`, transporté par `zsh ${HV_RUNNER_DIR}/vm.sh ssh`.
7. Lancer exactement :

```bash
zsh ${HV_RUNNER_DIR}/vm.sh exec env HV_UI_BACKEND=orb \
  bash .cursor/skills/verify-hermed-bots/scripts/hv-run.sh ui fake
```

Les variables déjà exportées (`HV_TEST_API_KEYS`, `HV_TEST_PROFILE_TABLE`, `HV_API_URL`, `HV_XCTESTRUN`, `HV_UNDER_RUNNER`) traversent `env` sans figurer sur la ligne de commande.

8. Dernière ligne : `HV-UI chemin=vm|attente rc=… durée=… preuves=…`. Le code de `hv-run.sh` est renvoyé tel quel (10 test FAIL, 12 référence manquante, 15 capture absente, 20 chemin protégé modifié, 40 `HV_XCTESTRUN` ou xcodebuild absent).

### Invité (`guest <evidence> <xctestrun>`)

1. `xcodebuild` et le fichier `.xctestrun` doivent exister, sinon code 40.
2. `TEST_RUNNER_HV_TEST_MODE=1`, `TEST_RUNNER_HV_API_URL` (l'URL du tunnel, `http://127.0.0.1:${HV_PORT:-18642}`), `TEST_RUNNER_HV_TEST_API_KEYS`, `TEST_RUNNER_HV_TEST_PROFILE_TABLE`, `TEST_RUNNER_HV_SHOTS=<evidence>/shots`.
3. `xcodebuild test-without-building -xctestrun <xctestrun> -destination 'platform=macOS' -resultBundlePath <evidence>/result.xcresult`. Journal : `<evidence>/xcodebuild.log`.
4. `LiveTunnel` vérifie `GET /p/hv-bot-a/v1/models` et `GET /p/hv-bot-b/v1/models` en HTTP 200 avec la clé du profil, lance l'app, clique `hd.bots.row.hv-bot-a` et `hd.bots.row.hv-bot-b`, attend `hd.status.version` égal à la version de `/p/hv-bot-a/health`, refuse `hd.banner.error`, et capture `issue56-hv-bot-a` / `issue56-hv-bot-b` via `HVShot.capture`.
5. Code 10 si xcodebuild est non nul. Les captures restent des pièces jointes du xcresult : `hv-run.sh` les exporte ensuite (`hv-shotdiff.sh --export`, code 15 si une ligne `HV-SHOT` n'a pas d'image) et compare aux PNG de `baselines/` (codes 11, 12, 13).

Sélecteurs : uniquement les `accessibilityIdentifier` stables (`hd.bots.row.<profileId>`, `hd.status.version`, `hd.composer.input`, `hd.banner.error`). Jamais un libellé traduit.

## Gotchas

- Une seule VM de test à la fois. Remettre la MAC d'origine (`VMUI_MAC`) : une MAC neuve rend l'invité injoignable.
- Dans la VM, `/usr/bin` en tête du `PATH` : `socket.getfqdn` d'un Python Homebrew attend le DNS bloqué par pf.
- Ne pas tuer `Setup Assistant` : sa mort casse Aqua et xcodebuild ne joint plus `testmanagerd` (code 15).
- SIP désactivé dans la VM : aucun secret durable. Le fichier de clés reste sur l'hôte, sous `$HV_WORK/secrets/`, mode 600.
- `hv-guard.sh` relève l'hôte avant et après. Changement → code 20. `hv-run.sh` refait sa garde dans la VM.
- Les anciennes lanes de fixtures restent distinctes de cette lane réelle.
