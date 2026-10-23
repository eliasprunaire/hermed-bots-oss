#!/usr/bin/env bash
# render-net-guard.sh <sortie.png> <sortie-passe>... <journal-lane5> : la lane 10 de HD-10, rendue en image
# Chaque <sortie-passe> est la sortie de `<vm-test-script> exec bash docs/spike/hd10-instruments/run-ui.sh ...` ; son dossier de preuves et le dossier du module (meta) s'y lisent
# On en tire : le mode du faux serveur, les lignes NET et GUARD de la passe, la garde de l'hôte avant et après (guard-host-*.txt du module), et les destinations lues dans net.txt
# <journal-lane5> est lane.log de lane-orb-model.sh : la garde de la lane 5, sur l'hôte
# Le PNG est une transcription de terminal rendue en image, pas une capture de l'app
set -uo pipefail
PNG=${1:?usage: render-net-guard.sh <sortie.png> <sortie-passe>... <journal-lane5>}
shift
[ $# -ge 2 ] || { echo "usage: render-net-guard.sh <sortie.png> <sortie-passe>... <journal-lane5>" >&2; exit 2; }
LANE5=${!#}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
WORK=$(mktemp -d)
{
  echo "HD-10 lane 10 code=$(git -C "$REPO" rev-parse --short HEAD) rendu=$(TZ=Europe/Paris date '+%Y-%m-%d %H:%M:%S') Paris"
  echo "Transcription de terminal rendue en image, pas une capture de l'app : relevés lsof de l'app et garde des chemins protégés autour des lanes 1 à 9"
  for pass in "${@:1:$#-1}"; do
    echo
    echo "================ $(sed -n 's/^faux serveur \(mode=[^ ]* drop=[^ ]*\).*/\1/p' "$pass" | head -1)"
    ui=$(grep '^HV-UI ' "$pass" | tail -1)
    evd=$(printf '%s' "$ui" | sed -n 's/.*preuves=\([^ ]*\).*/\1/p')
    meta=$(printf '%s' "$ui" | sed -n 's/.*meta=\([^ ]*\).*/\1/p')
    grep -E 'Executed [0-9]+ tests?, with' "$pass" | sed 's/^[[:space:]]*//' | tail -1
    grep -E '^(NET (OK|FAIL)|GUARD )' "$pass"
    echo "garde de l'hôte avant la passe : $(tr '\n' ' ' < "$meta/guard-host-before.txt")"
    echo "garde de l'hôte après la passe : $(cat "$meta/guard-host-after.txt")"
    echo "destinations distinctes dans net.txt : $(awk '{ n = split($3, p, "->"); if (n == 2) print p[2] }' "$evd/net.txt" | sort -u | tr '\n' ' ')"
    printf '%s\n' "$ui" | cut -c1-230
  done
  echo
  echo "================ lane 5 sur l'hôte (hd-probe contre hv-hermes-test)"
  grep -E 'GUARD|RESULT' "$LANE5" | cut -c1-230
} > "$WORK/render.txt"
fold -w 118 -s "$WORK/render.txt" > "$WORK/render.fold.txt"
magick -background '#1e1e1e' -fill '#e6e6e6' -font /System/Library/Fonts/Menlo.ttc -pointsize 15 "label:@$WORK/render.fold.txt" -bordercolor '#1e1e1e' -border 16 "$PNG"
cat "$WORK/render.txt"
echo "PNG $PNG (brouillon dans $WORK)"
