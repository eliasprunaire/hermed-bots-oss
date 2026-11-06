# Reprise, erreurs et événement inconnu

Après une coupure (veille simulée), l'app rouvre la connexion et relit le tour sans renvoyer de message ; API injoignable ou lente donne un bandeau propre ; un événement inconnu est ignoré.

## Sub-features

- `resume-cut` : reprise après coupure réseau simulée.
- `resume-inject` : reprise déclenchée par événement injecté.
- `error-down`, `error-slow` : bandeau `hd.banner.error`.
- `error-connecting` : pendant les tentatives (0 → 400 ms → 1,2 s) et la relecture de clé, `hd.banner.waiting` / pied « Connexion… », jamais un 401 flash.
- `event-unknown` : `hv.unknown_future_event` ignoré.

## How to get to it (user POV)

- Utilisation normale ; les erreurs apparaissent en bandeau haut de fenêtre.

## Driving it with XCUITest

- **Coupure.** Pendant un tour : fake `curl -X POST -d '{"seconds":10}' http://127.0.0.1:${HV_PORT}/_hv/cut` ; orb `docker network disconnect` puis `connect` sur `${HV_CONTAINER}`. Au retour : résultat du tour affiché, `/_hv/log` montre un seul `send_message`.
- **Injecté.** `curl -X POST -d '{"event":"run.completed"}' .../_hv/inject`.
- **Injoignable.** `HV_FAKE_MODE=down` : `hd.banner.error` visible en < 10 s, `hd.banner.error.retry` présent, fenêtre réactive. Capture `error`.
- **Lent.** `HV_FAKE_MODE=slow` (8 s) : indicateur d'attente, pas de gel, pas de double requête.
- **Inconnu.** Flux de la fixture contenant `hv.unknown_future_event` : tour terminé, aucune erreur.
- **Bords.** Clé fausse (401) : « Connexion… » pendant les essais, puis message clair, pas de boucle infinie. Coupure de 0 s, de 10 min. Aucune requête `list_sessions` sans Bearer si la clé du profil manque.

## Gotchas

- Relecture d'un tour : `GET /p/{profile}/v1/runs/{run}/events` avec l'en-tête `Last-Event-ID: N` (S2). Après un redémarrage de Hermes, le tour est `interrupted` et ses événements sont perdus (404).
- La veille réelle du Mac reste manuelle (A3).
