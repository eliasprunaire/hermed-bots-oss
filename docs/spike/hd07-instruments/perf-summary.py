#!/usr/bin/env python3
"""perf-summary.py <perf.txt> <nombre> : médianes trunk et head, et verdict de la règle de perf de HD-07
Une ligne de perf.txt : `<côté> <numéro> rc=<code de xcodebuild> HV-PERF07 mode=<mode> ms=<durée>`
Une mesure compte seulement si xcodebuild a rendu 0 et si la durée est un entier
Chaque côté doit avoir exactement <nombre> mesures valides : une série incomplète donne FAIL"""
import statistics
import sys

BUDGET_MS = 2000

path, wanted = sys.argv[1], int(sys.argv[2])
if wanted < 1:
    print("RESULT FAIL : le nombre de mesures doit valoir 1 au moins")
    sys.exit(1)
rows = {"trunk": [], "head": []}
for line in open(path, errors="replace"):
    parts = line.split()
    if len(parts) < 3 or parts[0] not in rows:
        continue
    ms = next((p[3:] for p in parts if p.startswith("ms=")), "")
    if "rc=0" in parts and ms.isdigit():
        rows[parts[0]].append(int(ms))

complete = True
for side, label in (("trunk", "trunk (connexion directe)"), ("head", "head (tunnel)")):
    values = rows[side]
    plural = "s" if len(values) > 1 else ""
    print("%s : %d mesure%s valide%s sur %d" % (side, len(values), plural, plural, wanted))
    if len(values) != wanted:
        complete = False
    elif values:
        print("%s : %s ms, médiane %d ms" % (label, values, statistics.median(values)))

if not complete:
    print("RESULT FAIL : série incomplète")
    sys.exit(1)
delta = statistics.median(rows["head"]) - statistics.median(rows["trunk"])
ok = wanted > 0 and delta <= BUDGET_MS
print("écart de médianes head - trunk : %+d ms ; règle : échec au-delà de +%d ms" % (delta, BUDGET_MS))
print("RESULT %s" % ("OK" if ok else "FAIL"))
sys.exit(0 if ok else 1)
