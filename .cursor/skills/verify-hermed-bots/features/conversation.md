# Conversation et nouvelle session

Envoyer un message à un bot, voir la réponse en continu et l'état terminal du tour ; `/new` ferme la session et ouvre un contexte vide.

## Sub-features

- `chat-send` : envoi, réponse en flux.
- `chat-terminal-state` : terminé, échoué, annulé, interrompu affichés tels quels.
- `session-new` : bouton Nouvelle session (contrat `new_session`), l'ancienne devient un fil passé.

## How to get to it (user POV)

- Choisir un bot, taper dans le champ, appuyer sur Envoyer ou ⏎.
- Bouton Nouvelle session dans la barre d'outils.

## Driving it with XCUITest

- **Envoyer.** `app.textViews["hd.composer.input"].typeText("Bonjour hv")` ; `app.buttons["hd.composer.send"].click()`. Attendre `hd.conversation.message.*` contenant « Réponse de test » (fixture) puis `hd.conversation.state` = terminé. Capture `conversation`.
- **Effet de bord.** `GET /_hv/log` (fake) : exactement un `POST /p/hv-bot-a/api/sessions/<session>/chat` (décision S4 : le chat de session lit le verrou de modèle ; `POST /v1/runs` l'ignore).
- **Nouvelle session.** `hd.session.new` ; `/_hv/log` : un `POST /p/hv-bot-a/api/sessions` (le texte `/new` n'est pas interprété par l'API, S4) ; la conversation est vide ; `hd.threads.row.<ancienne>` apparaît sous le bot.
- **Bords.** Message vide ou espaces : Envoyer désactivé. Message de 100 000 caractères : pas de gel. Double clic sur Envoyer : un seul envoi. Envoi pendant un tour en cours : comportement défini, sinon FAIL.
- **État échec.** Événement terminal `run.failed`, `run.cancelled` ou `run.interrupted` (en orb, `HV_FAIL` provoque un échec) : `hd.conversation.state` le montre.

## Gotchas

- Le fil affiché n'est pas le contexte envoyé au modèle (PRD) : ne pas déduire le contexte de l'écran.
- La v1 n'utilise que `/new`, jamais `session.compress`.
