# Liste des bots et fils passés

La barre latérale liste les profils Hermes actifs (jamais les décommissionnés) ; sous chaque bot, les fils passés fermés par `/new` sont listés et rouvrables avec leur contexte.

## Sub-features

- `bots-list` : profils actifs lus dans Hermes. Aucune route HTTP ne liste les profils (S6). Décision S6 de l'issue #6 : un second canal SSH en lecture seule lit `hermes profile list`, et un profil au Gateway `stopped` (décommissionné) est exclu de la liste. Le contrat `list_profiles` reproduit cette lecture.
- `bots-change` : un changement de liste n'est affiché qu'après validation (A3).
- `threads-list` : fils passés sous le bot.
- `threads-reopen` : rouvrir un fil rend son contenu.

## How to get to it (user POV)

- Ouvrir l'app : la barre latérale apparaît.
- Déplier un bot pour voir ses fils passés ; cliquer un fil.

## Driving it with XCUITest

Préconditions : environnement prêt avec `hv-bot-a`, `hv-bot-b` actifs, `hv-old` inactif ; session passée `s-past-1` (faux serveur).

- **Liste.** `app.outlines["hd.bots.list"]` existe ; `hd.bots.row.hv-bot-a` et `hd.bots.row.hv-bot-b` existent ; `hd.bots.row.hv-old` **n'existe pas**. Capture `bots`.
- **Fils.** Cliquer `hd.bots.row.hv-bot-a` ; `hd.bots.row.hv-bot-a.threads` contient `hd.threads.row.s-past-1`.
- **Rouvrir.** Cliquer `hd.threads.row.s-past-1` ; `hd.conversation.view` montre ses messages. Capture `threads`.
- **Bords.** Liste vide (fixture sans profil) : message clair, pas de plantage. Nom de profil de 300 caractères, emoji, RTL : ligne tronquée lisible. Fil sans `title` (`HV_FAKE_MODE=fields`) ou à `title` nul (session neuve) : repli sur l'id du fil.

## Gotchas

- Ne jamais sélectionner par libellé : le `title` d'un fil peut changer.
- L'ordre d'affichage n'est pas un contrat ; vérifier la présence, pas l'index.
- La validation d'un changement de liste (A3) n'a pas encore d'UI définie : test en FAIL tant qu'elle manque.
