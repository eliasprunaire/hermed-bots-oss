# Conversation et chat unique

Envoyer un message à un bot, voir la réponse rendue en Markdown, l'attente « Le bot réfléchit… » et l'état terminal du tour. Un fil unique par bot ; le contexte se compacte aux seuils Hermes (50 % / 85 %).

## Sub-features

- `chat-send` : envoi, réponse en flux, rendu Markdown (gras, listes, tableaux, code).
- `chat-terminal-state` : terminé, échoué, annulé, interrompu affichés tels quels.
- `session-new` : bouton Nouvelle session (contrat `new_session`) : conversation vide, l'ancien fil n'est pas listé.
- `context-compact` : `hd.conversation.compacted` et pied `hd.status.compat` avec le pourcentage.

## How to get to it (user POV)

- Choisir un bot, taper dans le champ, appuyer sur Envoyer ou ⏎.
- Pendant l'attente : `hd.conversation.busy` = « Le bot réfléchit… ».
- Bouton Nouvelle session dans la barre d'outils.

## Driving it with XCUITest

- **Envoyer.** `app.textViews["hd.composer.input"].typeText("Bonjour hv")` ; `app.buttons["hd.composer.send"].click()`. Attendre `hd.conversation.message.*` contenant « Réponse de test » (fixture) puis `hd.conversation.state` = terminé. Capture `conversation`.
- **Effet de bord.** `GET /_hv/log` (fake) : un `POST /p/hv-bot-a/v1/runs` dans le fil unique (décision S4 : le chat de session lit le verrou de modèle ; `POST /v1/runs` l'ignore).
- **Nouvelle session.** `hd.session.new` ; `/_hv/log` : un `POST /p/hv-bot-a/api/sessions` ; la conversation est vide ; aucune `hd.threads.row.*`.
- **Bords.** Message vide ou espaces : Envoyer désactivé. Message de 100 000 caractères : pas de gel. Double clic sur Envoyer : un seul envoi. Envoi pendant un tour en cours : comportement défini, sinon FAIL.
- **État échec.** Événement terminal `run.failed`, `run.cancelled` ou `run.interrupted` (en orb, `HV_FAIL` provoque un échec) : `hd.conversation.state` le montre.

## Gotchas

- Le fil affiché n'est pas le contexte envoyé au modèle (PRD) : ne pas déduire le contexte de l'écran.
- La compaction UI s'aligne sur les seuils Hermes Agent (50 % / 85 %) ; `session.compress` n'est pas appelé par l'app.
- Si le flux porte `usage.total_tokens`, le bandeau `hd.conversation.compacted` et le pied utilisent ce signal serveur. Sinon l'UI estime d'après la taille du transcript : le bandeau dit « Estimation du contexte » et le pied ajoute « (estimation) ». Ne pas présenter une estimation comme un relevé Hermes.
