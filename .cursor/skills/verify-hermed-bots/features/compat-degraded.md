# Compatibilité et mode dégradé (A7, A10, A11)

Une nouvelle version de Hermes ne casse jamais l'app : champs inconnus ignorés, champ manquant = valeur par défaut, route disparue = fonction désactivée seule avec un message clair.

## Sub-features

- `compat-recent` : version récente / précédente (fixtures `hermes-current`, `hermes-previous`).
- `compat-fields` : champs ajoutés et retirés.
- `compat-route` : route supprimée => fonction désactivée seule.
- `compat-daily` : test quotidien 13 h 00 Paris.

## How to get to it (user POV)

- Bandeau `hd.banner.degraded` seulement si une fonction est réellement désactivée. Une version non testée dont tout répond : pied `hd.status.compat` (« Compatibilité · voir Réglages ») et détail dans Réglages → À propos (`hd.about.compat`). Version lue dans `hd.status.version`.

## Driving it with XCUITest

- **Récente.** `HV_FAKE_VERSION=previous scripts/hv-hermes-env.sh up fake` : les six actions passent ; `hd.status.version` montre la version, à titre d'information.
- **Champs.** `HV_FAKE_MODE=fields` : `zz_new_field` ignoré, `title` absent remplacé par l'id du fil ; aucune erreur.
- **Route.** `HV_FAKE_MODE=drop-route HV_DROP=set_model` : `hd.model.picker` désactivé, `hd.banner.degraded.feature.set_model` explique, conversation et approbation marchent. Capture `degraded`. Répéter avec `HV_DROP=approve`, `list_sessions`.
- **API seule.** `scripts/hv-run.sh compat`.
- **Quotidien.** `HV_UNDER_RUNNER=1 scripts/hv-run.sh daily orb` ; lire `rapport-quotidien.md` ; `ALERTE` seulement si FAIL ou chemin protégé modifié.

## Bandeaux HD-12

L'app sonde la carte des capacités au lancement, puis pour le bot sélectionné.
Le bandeau nomme chaque contrat désactivé avec son identifiant `hd.banner.degraded.feature.<contrat>`.
Une version inconnue ou non testée sans fonction perdue n'affiche pas de bandeau : le pied et les Réglages portent l'avis.

```text
API -> carte des capacités -> bandeau -> fonction concernée
```

La recette ciblée tourne dans la VM.

```bash
zsh ${HV_RUNNER_DIR}/vm.sh exec bash docs/spike/hd12-instruments/run-lanes.sh
```

La lane 8 utilise la fixture `previous`.
La lane 10 de ce script utilise le faux serveur.
Elle ne prouve pas le fonctionnement sur `${HV_CONTAINER}`.
Le lanceur garde les passes OrbStack en attente tant que son tunnel VM manque.

## Gotchas

- Les fixtures viennent des relevés du spike (`fixtures/README.md`). Un PASS contre le faux serveur prouve la fixture ; la preuve contre le vrai Hermes est `hv-run.sh api orb`.
- Aucune règle « refuser si la version diffère » ne doit subsister (A7 remplace le PRD).
