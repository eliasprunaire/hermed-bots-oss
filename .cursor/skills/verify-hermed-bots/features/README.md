# Feature map — Hermed Bots

Source de vérité de la vérification. Chaque fichier : ce que voit l'utilisateur, comment y aller, comment le piloter avec XCUITest (identifiants `hd.*`), pièges. Les routes Hermes citées sont celles relevées par le spike (`fixtures/README.md`, `docs/spike/`).

| Fonction | Fichier | Tests | Modèle |
|---|---|---|---|
| Liste des bots et chat unique | [bot-list.md](bot-list.md) | `SixActions.testListBots`, chat unique | aucun |
| Conversation et nouvelle session | [conversation.md](conversation.md) | `SixActions.testConversation` | aucun |
| Changement de modèle (`set_model`) | [model-switch.md](model-switch.md) | `SixActions.testModelSwitch` | aucun |
| Approbation et outil en cours | [approval.md](approval.md) | `testApprovalYes/No`, `testCurrentTool` | aucun |
| Reprise, erreurs, événement inconnu | [resume-and-errors.md](resume-and-errors.md) | `testResumeAfterSleep`, `Errors.*`, `Events.*` | aucun |
| Compatibilité et mode dégradé | [compat-degraded.md](compat-degraded.md) | `Compat.*`, test quotidien | aucun (Haiku pour le rapport) |
| Lane UI réelle (VM + tunnel inverse) | [vm-tunnel.md](vm-tunnel.md) | `LiveTunnel.testRealTestProfilesThroughTheVMTunnel` | aucun |

Jugement d'un résultat ambigu : Sonnet ou Codex, autre fournisseur que l'auteur (règle 14).
