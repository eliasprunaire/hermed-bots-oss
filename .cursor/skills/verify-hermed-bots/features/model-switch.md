# Changement de modèle (set_model)

Le sélecteur change le modèle de la session ouverte par le contrat `set_model` (pas le modèle du profil). Le texte `/model` envoyé comme message n'est pas interprété par l'API (S4).

## Sub-features

- `model-pick` : choisir un modèle.
- `model-persist` : le choix reste sur cette session, pas sur les nouvelles.

## How to get to it (user POV)

- Menu `Modèle` dans l'en-tête de la conversation.

## Driving it with XCUITest

- **Choisir.** `app.popUpButtons["hd.model.picker"].click()` ; `app.menuItems["hd.model.option.model-y"].click()`. Capture `model-picker`.
- **Effet de bord.** `/_hv/log` : `POST /p/hv-bot-a/api/sessions/<session>/model` avec le modèle choisi dans le corps `{"model": ...}`.
- **Persistance.** `hd.session.new` puis relire `hd.model.picker` : modèle du profil, pas `model-y`.
- **Bords.** Modèle inconnu renvoyé par Hermes : affiché tel quel, sans plantage. Route retirée (`HV_FAKE_MODE=drop-route`) : sélecteur désactivé seul, voir `compat-degraded.md`.

## Gotchas

- Le sélecteur du dashboard Hermes écrit le profil ; ne pas confondre.
- Le verrou de modèle est lu par `POST /api/sessions/{id}/chat` et `.../chat/stream`, pas par `POST /v1/runs` (S4). Le contrat `send_message` utilise le chat de session (décision S4 de l'issue #6) : deux messages envoyés dans la session après `set_model` répondent avec le modèle choisi (`runtime.route_source` = `session_model_lock`). Un tour lancé par `start_run` (`POST /v1/runs`) ignore le choix.
