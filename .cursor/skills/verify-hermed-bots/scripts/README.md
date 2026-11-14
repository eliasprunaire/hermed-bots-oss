# hv-noise.js

Mesure le bruit de rendu entre **deux dossiers de captures PNG prises au même SHA**.

Le script est en Node (`hv-noise.js`) plutôt qu’en bash : la CI n’a pas ImageMagick, les tests tournent avec `node --test`, et `--json` s’écrit sans parseur. Le verdict reste celui de `hv-shotdiff.sh`, appelé tel quel — pas de copie de sa règle de zone, pas de modification de ce fichier.

## Usage

Depuis la racine du dépôt :

```bash
node .cursor/skills/verify-hermed-bots/scripts/hv-noise.js <passe-1> <passe-2>
node .cursor/skills/verify-hermed-bots/scripts/hv-noise.js --json <passe-1> <passe-2>
node .cursor/skills/verify-hermed-bots/scripts/hv-noise.js --help
```

`<passe-1>` et `<passe-2>` sont les dossiers `shots` de deux passes UI du même SHA.

## Colonnes

| Colonne | Sens |
| --- | --- |
| px | Pixels différents au fuzz 5 % (même seuil RGB qu’`hv-shotdiff.sh`) |
| dist | Plus grande distance de couleur (Euclidienne RGB, composite sur fond 0 et 255) |
| boîte | Englobante des différences, format `x,y,lxh` |
| décal | Translation entière de 0 à 4 px qui minimise le ratio de pixels différents |
| shotdiff | Verdict de `hv-shotdiff.sh` avec la tolérance de `main` (0,02) |

Les PNG présents d’un seul côté sont listés à part. Aucune écriture hors d’un dossier temporaire, aucune promotion de référence, aucun réseau.

## Mesure locale des deux passes

Après deux passes UI au même SHA, comparer leurs dossiers de captures :

```bash
node .cursor/skills/verify-hermed-bots/scripts/hv-noise.js --json <captures-passe-1> <captures-passe-2>
```

Les fixtures de test : `test/fixtures/noise/pass-a` et `test/fixtures/noise/pass-b`.
