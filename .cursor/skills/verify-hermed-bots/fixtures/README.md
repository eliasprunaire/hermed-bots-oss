# Fixtures de contrat Hermes (A10)

Une fixture par version prise en charge : `hermes-current/` (Hermes 0.22.2) et `hermes-previous/` (Hermes 0.22.1). Décision Q11 : `current` est `latest`, `previous` est la release juste avant `latest`. Le nom logique des contrats (`list_profiles`, `send_message`, ...) reste stable d'une version à l'autre et c'est lui que les rapports citent.

Chaque route, méthode et champ vient d'une requête réelle sur un conteneur jetable (image `${HV_HERMES_IMAGE}` pour `current` et sa précédente pour `previous`, même amorçage `orb/hv-start.sh`, modèle factice Q6 s1). Les rapports `docs/spike/S1` à `S7` donnent les références doc et code. Les sondes de bord et la version précédente sont relevées par HD-02. Le spike n'a rien noté d'impossible : aucun marqueur de supposition ne reste dans ce dossier.

## Format de `contract.json`

| Clé | Contenu |
| --- | --- |
| `version` | version de Hermes relevée, la même que `contracts.version.response.version` |
| `observed` | date, conteneur et image du relevé |
| `optional_fields` | champs que l'app doit tolérer absents. Le mode `fields` du faux serveur retire le premier |
| `profiles.served` | profils servis par le préfixe `/p/{profile}`. Tout autre nom, `hv-old` compris, reçoit 404 |
| `profiles.stopped` | profils au Gateway `stopped` dans `hermes profile list` (décommissionnés), exclus de la liste |
| `contracts.<nom>` | `method`, `path`, `status` attendu, `response` (corps JSON de référence ou `"SSE"`). Facultatifs : `body` (corps envoyé), `auth: false` (route sans clé), `setup` (tour à lancer avant l'appel : `input` et événement `wait` à attendre), `repeat` (nombre d'envois dans la même session), `expect` (valeurs exactes, chemin pointé), `expect_locked` (valeurs exactes, vérifiées seulement si `set_model` a réussi), `note`. `list_profiles` n'a ni `method` ni `path` : `transport: "ssh"`, `command`, `read_only`, `exit`, `stopped_gateway`, `output` (table observée) |
| `events` | suite d'événements du flux d'un tour, au format observé, avec l'événement inconnu voulu `hv.unknown_future_event` |
| `edges` | sondes de bord : requête et statut observé |

Variables de chemin : `{profile}` (le profil sondé, `hv-bot-a`), `{session}` et `{run}` (identifiants créés par la sonde). Dans les réponses, `{new_session}` et `{new_run}` sont des identifiants que le faux serveur crée à chaque appel. Dans un `body`, `$nom` prend la valeur du champ `nom` de l'événement attendu par `setup.wait`.

Les valeurs de `response` sont des exemples. La sonde compare les noms de champs, jamais les valeurs, sauf celles de `expect` et `expect_locked`. Une liste de la référence doit être une liste dans la réponse, et chaque élément suit l'élément de référence : `data: null`, une chaîne ou un élément sans `id` donnent FAIL. Une liste vide passe.

## Contrats

Tous les chemins portent le préfixe de profil `/p/{profile}`, sauf `version`. Le port est unique (S7).

| Contrat | Méthode et chemin | Statut | Rapport |
| --- | --- | --- | --- |
| `version` | `GET /health` (sans clé) | 200 | S7 |
| `list_profiles` | `hermes profile list` par un canal SSH en lecture seule | code 0 | S6 |
| `profile_served` | `GET /p/{profile}/v1/models` | 200 | S6 |
| `list_sessions` | `GET /p/{profile}/api/sessions` | 200 | S5 |
| `new_session` | `POST /p/{profile}/api/sessions` | 201 | S4 |
| `send_message` | `POST /p/{profile}/api/sessions/{session}/chat` (corps `{"input": ...}`), deux fois | 200 | S1, S4 |
| `start_run` | `POST /p/{profile}/v1/runs` (corps `{"input": ...}`) | 202 | S1 |
| `run_events` | `GET /p/{profile}/v1/runs/{run}/events` (SSE) | 200 | S1, S2 |
| `set_model` | `POST /p/{profile}/api/sessions/{session}/model` | 200 | S4 |
| `approve` | `POST /p/{profile}/v1/runs/{run}/approval` | 200 | S1 |
| `cancel_run` | `POST /p/{profile}/v1/runs/{run}/stop` | 200 | S3 |

`list_profiles` (décision S6 de l'issue #6) : aucune route HTTP ne liste les profils. L'app lit `hermes profile list` par un second canal SSH en lecture seule. Un profil au Gateway `stopped` est décommissionné et exclu. La sonde exécute la commande par `--profile-cmd` (en orb, `docker exec` dans `${HV_CONTAINER}` avec `${HV_HERMES_USER}` et `${HV_HERMES_HOME}` tient lieu de SSH), compare les profils actifs à `profiles.served` et les arrêtés à `profiles.stopped`, puis vérifie sur le port API que chaque actif répond 200 et chaque arrêté 404. Sans `--profile-cmd`, le faux serveur sert la table sur `/_hv/profile-list`. Seule la commande `hermes profile list` est acceptée.

`send_message` (décision S4 de l'issue #6) : le tour passe par le chat de session, qui lit le verrou de modèle. Les deux messages partent dans la session de `new_session`, après `set_model` : `session_id` identique, `runtime.model` et `runtime.route_source` (`session_model_lock`) du modèle verrouillé. `start_run` garde `POST /v1/runs` pour les tours à événements (`run_events`, `approve`, `cancel_run`), qui ignore le verrou.

Le flux `run_events` envoie `id: N` puis `data: {"event": ..., "seq": N}`, les commentaires `: open` et `: stream closed`, et `Last-Event-ID` reprend après `N`. Le vrai Hermes ne ferme pas la connexion après `: stream closed` : le client s'arrête au premier événement terminal (`run.completed`, `run.failed`, `run.cancelled`, `run.interrupted`).

## Différences entre `previous` (0.22.1) et `current` (0.22.2)

| Point | 0.22.1 | 0.22.2 |
| --- | --- | --- |
| Corps de `approve` | exactement `request_id` (la valeur de `prompt_id` de l'événement), `execution_generation` (entier de l'événement) et `choice`. Un autre jeu de clés donne 400 `invalid_params` | `request_id` (de l'événement) et `choice` |
| Réponse de `approve` | `run_id`, `status: "resolved"`, `prompt_id` | `object`, `run_id`, `choice`, `request_id`, `resolved` |
| Événement `approval.request` | `kind`, `prompt_id`, `execution_generation`, pas de `request_id` | `request_id`, `pattern_key`, `pattern_keys`, `allow_permanent`, `allow_session` |
| Événement après la décision | `approval.settled` | `approval.responded` |
| Événements `tool.started` et `tool.completed` | portent `tool_call_id` | pas de `tool_call_id` |
| Événement `reasoning.available` | absent | présent |
| Réponse de `cancel_run` | porte `admission_id` en plus | `run_id` et `status` |

Les statuts HTTP des contrats et des sondes de bord sont identiques sur les deux versions.

## Sondes de bord

`hv-contract-check.py` envoie chaque sonde de `edges` et compare le statut. Les statuts sont ceux des deux conteneurs réels.

| Sonde | Requête | Statut |
| --- | --- | --- |
| `message-vide` | `POST /v1/runs` avec `{"input": ""}` | 400 |
| `run-inexistant` | `GET /v1/runs/run_nope/events` | 404 |
| `session-inexistante` | `POST /api/sessions/api_nope/model` | 404 |
| `id-negatif` | `GET /v1/runs/-1/events` | 404 |
| `session-negative` | `POST /api/sessions/-1/model` | 404 |
| `json-invalide` | `POST /v1/runs` avec `{pas du json` | 400 |
| `cle-absente` | `GET /api/sessions` sans en-tête `Authorization` | 401 |
| `profil-parque` | `GET /p/hv-old/v1/models` | 404 |
| `liste-http-absente` | `GET /v1/profiles` | 404 |
| `chat-message-vide` | `POST /api/sessions/{session}/chat` avec `{"input": ""}` | 400 |
| `chat-session-inexistante` | `POST /api/sessions/api_nope/chat` | 404 |

Deux comportements du vrai Hermes ne sont pas des erreurs : un message d'espaces `{"input": "   "}` est accepté (202), et `POST /v1/runs` avec un `session_id` inconnu ou négatif est accepté (202).

## Faux serveur

`scripts/hv-fake-hermes.py` sert ces fichiers sur 127.0.0.1. Modes (`HV_FAKE_MODE`) :

- `normal` : les routes observées.
- `slow` : chaque réponse attend 8 s.
- `down` : 503 partout.
- `drop-route` : le contrat nommé par `HV_DROP` (défaut `set_model`) reçoit 404.
- `fields` : ajoute `zz_new_field` dans chaque objet JSON et retire le premier champ de `optional_fields`.
- `malformed` : contrôles négatifs, choisis par `HV_MALFORMED`. `null`, `string` et `noid` abîment chaque liste `data` (null, chaîne, second élément sans `id`). `leak` liste `hv-old` comme actif. `nolock` ignore le verrou de modèle.

`POST /_hv/config` accepte aussi `fail_without_text` (opt-in, hors `HV_FAKE_MODE`) : le tour n'émet pas le texte assistant de la fixture. Les scénarios hd09-failed et hd09-failed-error restent sans texte ; hd09-cancelled et hd09-interrupted reçoivent un delta visiblement tronqué.

Le faux serveur valide ce que la sonde de bord exige : clé absente (401), JSON invalide ou clé de `body` absente ou vide (400), profil ou identifiant inconnu (404). Il garde en mémoire les tours, les sessions et le modèle verrouillé de chaque session qu'il a créés.

Différences voulues avec le vrai Hermes :

- le faux serveur ferme la connexion après `: stream closed` ;
- il envoie la même suite d'événements pour tous les tours, y compris `approval.request` ;
- il ne gère pas `Idempotency-Key` et ne tient pas d'état d'approbation ;
- il expose les routes de test `/_hv/ready`, `/_hv/inject`, `/_hv/cut`, `/_hv/log`, `/_hv/profile-list`, `/_hv/config` et `/_hv/reset`.

## Relever à nouveau

```
export HV_TEST_API_KEY=$(openssl rand -hex 24)
.cursor/skills/verify-hermed-bots/scripts/hv-hermes-env.sh up orb
python3 .cursor/skills/verify-hermed-bots/scripts/hv-contract-check.py --url "http://127.0.0.1:${HV_PORT}" --fixture .cursor/skills/verify-hermed-bots/fixtures/hermes-current/contract.json --out "$HV_WORK/contracts.json"
.cursor/skills/verify-hermed-bots/scripts/hv-hermes-env.sh down orb
```

Pour `previous` : reconstruire l'image depuis `orb/Dockerfile` avec `HERMES_IMAGE` de la version précédente, puis `up orb` avec `${HV_HERMES_IMAGE}`, `${HV_CONTAINER}` et `${HV_PORT}` distincts, et la fixture `hermes-previous`.
