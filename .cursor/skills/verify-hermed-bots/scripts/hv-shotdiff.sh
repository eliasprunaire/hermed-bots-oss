#!/usr/bin/env bash
# hv-shotdiff.sh — compare les captures d'une passe aux références. Modèle : aucun.
# Usage : hv-shotdiff.sh <dossier-captures> <dossier-baselines> <dossier-diffs> [tolérance=0.02]
#         hv-shotdiff.sh --export <xcresult> <dossier-captures> [nom-attendu...]   # pièces jointes PNG -> <nom>.png
#         hv-shotdiff.sh --bless <dossier-captures> <dossier-baselines>   # promeut (humain seulement)
# Tolérance = fraction de pixels différents (fuzz 5 % par pixel). Outil : ImageMagick `compare`
# (brew install imagemagick). Codes : 0 OK ; 2 usage ; 11 écart > tolérance ; 12 baseline manquante ;
# 13 outil absent ; 15 captures absentes (dossier absent ou sans PNG, export impossible, nom attendu manquant).
# Le runner XCUITest est sandboxé : il n'écrit pas dans le dossier des captures, qui vient de --export.
# Le jugement visuel final reste manuel (A3) : ce script ne fait que trier.
set -euo pipefail
if [ "${1:-}" = --bless ]; then
  [ $# -eq 3 ] || { echo "usage: $0 --bless <captures> <baselines>" >&2; exit 2; }
  mkdir -p "$3"; cp -v "$2"/*.png "$3"/; exit 0
fi
if [ "${1:-}" = --export ]; then
  [ $# -ge 3 ] || { echo "usage: $0 --export <xcresult> <captures> [nom-attendu...]" >&2; exit 2; }
  RES=$2; CAP=$3; shift 3
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  xcrun xcresulttool export attachments --path "$RES" --output-path "$TMP" --filter '*.png' > "$TMP/export.log" 2>&1 \
    || { echo "SHOT FAIL (15): export des pièces jointes de $RES impossible : $(tail -2 "$TMP/export.log")" >&2; exit 15; }
  mkdir -p "$CAP"
  # une pièce jointe se nomme <nom>_<n>_<UUID>.png : on garde <nom> ; pas de exec, pour que le trap nettoie $TMP
  python3 -I - "$TMP" "$CAP" "$@" <<'PY'
import json, os, re, shutil, sys
tmp, cap, expected = sys.argv[1], sys.argv[2], sys.argv[3:]
got = set()
for test in json.load(open(os.path.join(tmp, "manifest.json"), encoding="utf-8")):
    for a in test["attachments"]:
        human = a["suggestedHumanReadableName"]
        if not human.endswith(".png"):
            continue
        m = re.fullmatch(r"(.*?)_\d+_[0-9A-Za-z-]+\.png", human)
        name = m.group(1) if m else human.removesuffix(".png")
        shutil.copyfile(os.path.join(tmp, a["exportedFileName"]), os.path.join(cap, name + ".png"))
        got.add(name)
missing = [n for n in expected if n not in got]
if missing or not got:
    print("SHOT FAIL (15): " + ("capture attendue absente du xcresult : " + ", ".join(missing) if missing else "aucune capture dans le xcresult"), file=sys.stderr)
    sys.exit(15)
print("EXPORT OK %d capture(s) : %s" % (len(got), ", ".join(sorted(got))))
PY
  exit $?
fi
[ $# -ge 3 ] || { echo "usage: $0 <captures> <baselines> <diffs> [tol]" >&2; exit 2; }
CAP=$1; BASE=$2; DIF=$3; TOL=${4:-0.02}
compgen -G "$CAP/*.png" >/dev/null || { echo "SHOT FAIL (15): aucune capture dans $CAP" >&2; exit 15; }
command -v compare >/dev/null 2>&1 || { echo "SHOT FAIL (13): ImageMagick 'compare' absent" >&2; exit 13; }
mkdir -p "$DIF"; rc=0
# Locale C : compare/identify/awk doivent produire un point décimal (fr_FR sinon → virgule → faux OK).
export LC_ALL=C
export LC_NUMERIC=C
for f in "$CAP"/*.png; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  if [ ! -f "$BASE/$n" ]; then echo "MISSING $n"; [ $rc -eq 0 ] && rc=12; continue; fi
  bw=$(identify -format '%w' "$BASE/$n"); bw=$(printf '%s' "$bw" | tr ',' '.')
  bh=$(identify -format '%h' "$BASE/$n"); bh=$(printf '%s' "$bh" | tr ',' '.')
  cw=$(identify -format '%w' "$f"); cw=$(printf '%s' "$cw" | tr ',' '.')
  ch=$(identify -format '%h' "$f"); ch=$(printf '%s' "$ch" | tr ',' '.')
  if [ "$bw" != "$cw" ] || [ "$bh" != "$ch" ]; then
    echo "DIFF $n size ${cw}x${ch} != baseline ${bw}x${bh}"
    rc=11
    continue
  fi
  px=$(compare -metric AE -fuzz 5% "$BASE/$n" "$f" "$DIF/$n" 2>&1 >/dev/null || true)
  # Normalise une éventuelle virgule décimale (locale parent) avant awk.
  px=${px%% *}
  px=$(printf '%s' "$px" | tr ',' '.')
  tot=$(identify -format '%[fx:w*h]' "$BASE/$n")
  tot=$(printf '%s' "$tot" | tr ',' '.')
  ratio=$(awk -v a="$px" -v b="$tot" 'BEGIN{ if (a !~ /^[0-9.e+]+$/) a=b; printf "%.5f", a/b }')
  if awk -v r="$ratio" -v t="$TOL" 'BEGIN{exit !(r>t)}'; then echo "DIFF $n ratio=$ratio > $TOL"; rc=11
  else echo "OK   $n ratio=$ratio"; rm -f "$DIF/$n"; fi
done
exit $rc
