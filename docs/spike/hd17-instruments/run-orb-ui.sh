#!/usr/bin/env bash
set -uo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
EVD="$HOME/hermed-bots-work/evidence/hd17-orb-ui-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$EVD"
{
  echo 'Cible attendue: hv-hermes-test via un tunnel du lanceur dans la VM.'
  echo 'Commande tentée: curl --noproxy "*" -fsS --max-time 3 http://127.0.0.1:18642/health'
  curl --noproxy '*' -fsS --max-time 3 http://127.0.0.1:18642/health
  rc=$?
  echo "curl rc=$rc"
  echo 'hd17-orb-profiles.png: passe UI en attente du tunnel VM vers hv-hermes-test, absent du lanceur.'
  echo 'Aucune clé réelle ni connexion extérieure injectée dans la VM.'
} > "$EVD/preflight.log" 2>&1
cat "$EVD/preflight.log"
exit 6
