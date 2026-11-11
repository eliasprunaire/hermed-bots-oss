# PNG de référence à régénérer

Les captures `baselines/*.png` se produisent sur le Mac, dans la VM du circuit de vérification (`hv-regen-baselines.sh`). Elles ne peuvent pas être générées sur une VM Linux.

Les 26 PNG déjà versionnés dans `UIReferences/` (hors `issue58-version-missing-key.png`, qui montre encore le bandeau global) ont été recopiés ici : ce sont des captures Mac existantes, pas des images inventées. Les noms ci-dessous n'ont toujours pas de binaire. Les produire puis les promouvoir :

1. Passe VM de la suite ordinaire `ui fake` (voir le README de ce dossier)
2. Examiner `reference-shots/` et `diffs/` dans le dossier annoncé par `HV-UI`
3. Promouvoir : `bash .cursor/skills/verify-hermed-bots/scripts/hv-shotdiff.sh --bless <reference-shots> .cursor/skills/verify-hermed-bots/baselines`
4. Retirer de cette liste chaque nom promu

Noms encore absents :

- LACUNE binaire : `design-compact-conversation.png`
- LACUNE binaire : `design-compact-home.png`
- LACUNE binaire : `design-dark-conversation.png`
- LACUNE binaire : `design-dark-home.png`
- LACUNE binaire : `hd07-connection.png`
- LACUNE binaire : `hd07-refuse-prod.png`
- LACUNE binaire : `hd07-tunnel.png`
- LACUNE binaire : `hd07-wrong-key.png`
- LACUNE binaire : `hd08-orb-nine.png`
- LACUNE binaire : `hd09-orb-send.png`
- LACUNE binaire : `hd11-huge-params.png` — texte qui défile, 2,8 % de pixels différents entre deux captures pour un seuil de 2 %.
- LACUNE binaire : `hd12-notification-authorization.png`
- LACUNE binaire : `hd12-trunk-no-banners.png`
- LACUNE binaire : `hd13-cut-trunk.png`
- LACUNE binaire : `hd13-local-state.png`
- LACUNE binaire : `hd13-loop-guard.png`
- LACUNE binaire : `hd13-ten-min-banner.png`
- LACUNE binaire : `hd14-approval.png`
- LACUNE binaire : `hd14-drop.png`
- LACUNE binaire : `hd14-held.png`
- LACUNE binaire : `hd14-no-write.png`
- LACUNE binaire : `hd14-other.png`
- LACUNE binaire : `hd14-release.png`
- LACUNE binaire : `hd14-taken.png`
- LACUNE binaire : `hd14-trunk-held.png`
- LACUNE binaire : `hd15-approval.png`
- LACUNE binaire : `hd15-double.png`
- LACUNE binaire : `hd15-drop.png`
- LACUNE binaire : `hd15-idle.png`
- LACUNE binaire : `hd15-kept.png`
- LACUNE binaire : `hd15-no-tunnel.png`
- LACUNE binaire : `hd15-stop-all.png`
- LACUNE binaire : `hd15-trunk-no-button.png`
- LACUNE binaire : `issue56-hv-bot-a.png`
- LACUNE binaire : `issue56-hv-bot-b.png`
- LACUNE binaire : `issue58-version-missing-key.png`
