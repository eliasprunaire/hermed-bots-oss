# Approbation et outil en cours

Quand le bot demande un outil, une feuille montre l'outil et ses paramètres avant toute réponse ; pendant un appel, la ligne « outil en cours » affiche son nom.

## Sub-features

- `approval-show` : outil + paramètres visibles avant réponse.
- `approval-yes` / `approval-no` : le bot continue ou renonce.
- `tool-current` : nom de l'outil pendant l'appel.

## How to get to it (user POV)

- Envoyer un message qui déclenche un outil ; la feuille s'ouvre d'elle-même. En orb, le message `HV_TOOL_DETACH go` déclenche l'approbation (modèle factice `orb/fake-llm.py`).

## Driving it with XCUITest

- **Outil en cours.** Après envoi, attendre `hd.tool.current` = `terminal` (événement `tool.started`). Capture `tool-current`.
- **Feuille.** `app.sheets["hd.approval.sheet"]` ; `hd.approval.tool` = `terminal` ; `hd.approval.params` contient la commande de l'événement `approval.request` (`python3 -c ...`) et sa description. Capture `approval`.
- **Oui.** `hd.approval.yes` ; `/_hv/log` : `POST /p/hv-bot-a/v1/runs/<run>/approval` avec `choice` = `once` ; le tour continue jusqu'à terminé.
- **Non.** Relancer, `hd.approval.no` ; `POST` avec `choice` = `deny` ; le tour renonce, état affiché.
- **Bords.** Paramètres énormes ou binaires : feuille défilante, jamais tronquée sans indication. Double clic Oui : une seule décision. Approbation pendant une coupure (`/_hv/cut`) : la feuille reste, la décision part au retour, une seule fois.

## Gotchas

- Choix possibles : `once`, `session`, `always`, `deny`. Corps de `approve` : `request_id` et `choice` en 0.22.2 ; `request_id` (valeur de `prompt_id`), `execution_generation` et `choice` en 0.22.1 (`fixtures/README.md`).
- L'écran ne doit jamais rester figé sans raison (PRD) : timeout de test 30 s puis FAIL.
