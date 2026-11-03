---
style_gate: pass
---

# Comparer les captures UI

Les PNG de ce dossier viennent de la VM de test macOS provisionnée selon la doc interne (`${HV_UI_GOLDEN}`).
La suite ordinaire utilise les fixtures Hermes du dépôt.
Les deux captures `issue56-hv-bot-*.png` proviennent de la passe réelle de #59, déjà versionnée dans `evidence/issue56/`.
Les captures réelles d'une passe restent dans `$HV_WORK/evidence/ui-*-vm/shots/`.

```text
Tart -> XCUITest -> pièces jointes xcresult -> shots/*.png -> comparaison -> diffs/*.png
```

La comparaison utilise la métrique AE d'[ImageMagick](https://imagemagick.org/compare/).
AE compte les pixels différents, avec une tolérance de couleur de 5 % par pixel.
Le test accepte au plus 2 % de pixels différents sur l'image entière.
Un changement de dimensions échoue aussi.
Aucun masque ne cache de région de la fenêtre.
La vidéo HD12 compare ses six états de contrôle `hd12-video-000.png` à `hd12-video-005.png`.
Ses images intermédiaires dépendent de la durée des actions.
Elles restent dans `shots/` comme artefacts, sans comparaison.
Le dossier `reference-shots/` contient les captures effectivement comparées.

La passe conserve l'image de différence dans `diffs/<nom>.png` lorsque l'écart dépasse le seuil.
Le code 11 fait échouer la passe.
Une référence manquante renvoie 12.
Un comparateur absent ou en erreur renvoie 13.
Une capture absente renvoie 15.
Le runner propage ces erreurs.

## Lancer la comparaison

Depuis la racine du dépôt, lancer uniquement le module VM.

```bash
timeout 3600 zsh ${HV_RUNNER_DIR}/vm.sh ui fake
```

La dernière ligne `HV-UI chemin=vm rc=0 ...` prouve la fin de la passe et de la comparaison.
Le code 6 signifie « passe UI en attente de la VM ».
Aucun repli ne lance l'app sur l'hôte.

## Régénérer les références

1. Lancer la commande VM ci-dessus sur le changement à examiner.
2. Examiner les captures et leurs différences dans le dossier de preuves indiqué par `HV-UI`.
3. Promouvoir les captures approuvées, puis commiter les PNG et la provenance dans la PR.

```bash
shots="$HV_WORK/evidence/ui-<horodatage>-vm/reference-shots"
bash .cursor/skills/verify-hermed-bots/scripts/hv-shotdiff.sh --bless \
  "$shots" .cursor/skills/verify-hermed-bots/baselines
```

La commande copie des captures existantes.
Elle ne lance aucune UI sur l'hôte.
Une passe ne promeut jamais automatiquement ses propres captures.
Les références couvrent la suite ordinaire `ui fake` et les deux captures LiveTunnel.
Les lanes spécialisées gardent leurs captures comme preuves, avec leur propre environnement.

## Rejouer les tests réactivés

L'[inventaire](../../../../docs/spike/issue57/skipped-tests.md) donne une décision pour chacun des 52 tests initiaux.
Cette commande exécute trois fois les neuf tests réactivés, dans une seule VM jetable.
Le script de lane échoue si un test demandé saute.

```bash
timeout 3600 zsh ${HV_RUNNER_DIR}/vm.sh exec \
  bash docs/spike/issue57/run-ui-repeat.sh
```

Les résultats et la provenance des références figurent dans `evidence/issue57/`.
