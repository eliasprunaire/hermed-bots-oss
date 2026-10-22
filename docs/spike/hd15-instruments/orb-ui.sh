#!/usr/bin/env bash
set -uo pipefail
[ "$HOME" =  ] || { echo 'VM hvtest requise'; exit 2; }
EVD=${HV_WORK:?}/evidence/hd15-orb-ui-$(date +%Y%m%d-%H%M%S)
mkdir -p "$EVD"
{
  echo 'HD15 lane 2 capture hd15-orb-tool.png. Tentative de joindre hv-hermes-test depuis la VM.'
  curl --connect-timeout 3 --max-time 5 -fsS http://192.0.2.10:18642/health
  code=$?
  echo "curl rc=$code"
  echo 'Lane 2 impossible sur UI OrbStack. Le tunnel VM vers hv-hermes-test manque dans vm.sh, pf interdit cet accès.'
  echo 'La sonde API distincte run-orb.sh ne prouve pas le clic UI.'
  echo 'HD15 lane 9 capture hd15-operator.png. Recherche du résultat manuel fourni par Ayo.'
  if test -s "$HV_WORK/hd15-operator-result.md"; then
    echo 'Résultat manuel présent, lecture opérateur nécessaire.'
  else
    echo "test -s \"$HV_WORK/hd15-operator-result.md\" rc=1. Impossible, aucun résultat manuel d’Ayo fourni."
  fi
} > "$EVD/attempt.log" 2>&1
cat "$EVD/attempt.log"
mkdir -p "$EVD/shots"
{
  echo 'HD15 lane 2. Preuve API distincte. Clic UI impossible, tunnel VM vers OrbStack absent.'
  grep -E '^HD15|GUARD|^[[:space:]]*[[:digit:]]+.* sleep 300$' docs/spike/hd15-orb.log
  cat "$EVD/attempt.log"
} > "$EVD/render.txt"
magick -background '#1e1e1e' -fill '#e6e6e6' -font /System/Library/Fonts/Menlo.ttc -pointsize 14 \
  "label:@$EVD/render.txt" -bordercolor '#1e1e1e' -border 16 "$EVD/shots/hd15-orb-tool.png"
exit 6
