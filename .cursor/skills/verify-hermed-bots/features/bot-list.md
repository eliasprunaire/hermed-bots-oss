# Liste des bots et chat unique

La barre latérale liste les profils Hermes actifs (jamais les décommissionnés). Un clic ouvre le fil unique du bot. Les sessions ne sont plus listées sous le bot.

## Sub-features

- `bots-list` : profils actifs lus dans Hermes. Aucune route HTTP ne liste les profils (S6). Décision S6 de l'issue #6 : un second canal SSH en lecture seule lit `hermes profile list`, et un profil au Gateway `stopped` (décommissionné) est exclu de la liste. Le contrat `list_profiles` reproduit cette lecture.
- `bots-change` : un changement de liste n'est affiché qu'après validation (A3).
- `unique-chat` : un fil par bot, repris au clic ; `list_sessions` sert à l'attacher, pas à l'afficher. Seul un fil `source=api_server` (ou sans `source`) est repris : un fil d'une autre surface (CLI, TUI, Desktop, messagerie) n'est pas lié ; le premier envoi crée un fil API.

## How to get to it (user POV)

- Ouvrir l'app : la barre latérale apparaît.
- Cliquer un bot pour ouvrir sa conversation unique.

## Driving it with XCUITest

Préconditions : environnement prêt avec `hv-bot-a`, `hv-bot-b` actifs, `hv-old` inactif ; session passée `s-past-1` (faux serveur).

- **Liste.** `app.outlines["hd.bots.list"]` existe ; `hd.bots.row.hv-bot-a` et `hd.bots.row.hv-bot-b` existent ; `hd.bots.row.hv-old` **n'existe pas**. Capture `bots`.
- **Chat unique.** Cliquer `hd.bots.row.hv-bot-a` ; `hd.conversation.view` s'ouvre ; `hd.bots.row.hv-bot-a.threads` et `hd.threads.row.*` **n'existent pas**.
- **Bords.** Liste vide (fixture sans profil) : message clair, pas de plantage. Nom de profil de 300 caractères, emoji, RTL : ligne tronquée lisible.

## Gotchas

- Ne jamais sélectionner par libellé.
- L'ordre d'affichage n'est pas un contrat ; vérifier la présence, pas l'index.
- La validation d'un changement de liste (A3) n'a pas encore d'UI définie : test en FAIL tant qu'elle manque.
