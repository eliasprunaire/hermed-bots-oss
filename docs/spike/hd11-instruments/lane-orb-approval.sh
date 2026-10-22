#!/usr/bin/env bash
# lane-orb-approval.sh <sortie.png> : lane 9 de HD-11, répondre à une approbation sur hv-hermes-test avec le faux fournisseur
# L'app ne tourne pas contre OrbStack : la VM de la passe UI n'atteint pas l'hôte (`vm.sh ui orb` rend « HV-UI SAUTÉE »), et l'app ne se lance jamais sur l'hôte
# Cette lane rejoue donc, avec hd-probe et HermesClient, les appels de la feuille : start_run, run_events jusqu'à approval.request, approve avec once (Oui) ou deny (Non)
# `HV_TOOL_DETACH go` fait lancer au faux fournisseur la commande `python3 -c "…subprocess.Popen(['sleep','303']…); os.system('sleep 300')"`, que Hermes soumet à l'approbation (« script execution via -e/-c flag »)
# Pass : chaque appel à hd-probe et à docker réussit ; après Non, aucun `sleep 303` ne tourne dans le conteneur et le tour finit `completed` ; après Oui, `sleep 303` tourne dans le conteneur (l'outil a tourné)
# La sortie montre aussi l'outil que la feuille nommerait (`tool=terminal`), pris du tool.started qui précède approval.request sur le vrai Hermes
# Le PNG est une transcription de terminal rendue en image, pas une capture de l'app
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
SK=$REPO/.cursor/skills/verify-hermed-bots/scripts
PNG=${1:?usage: lane-orb-approval.sh <sortie.png>}
WORK=${HV_WORK:-$HOME/hermed-bots-work}
EVD=$WORK/evidence/hd11-orb-$(TZ=Europe/Paris date +%Y%m%d-%H%M%S)
mkdir -p "$EVD"
LOG=$EVD/lane.log
URL=http://127.0.0.1:18642
CT=hv-hermes-test
say() { printf '[%s Paris] %s\n' "$(TZ=Europe/Paris date +%H:%M:%S)" "$*"; }

(cd "$REPO/Packages/HermesAdapter" && swift build --product hd-probe 2>&1 | tail -1) || exit 1
PROBE=$REPO/Packages/HermesAdapter/.build/debug/hd-probe

# la clé de test se tire au hasard, reste dans l'environnement de ce script et n'est jamais affichée
HV_TEST_API_KEY=$(openssl rand -hex 16); export HV_TEST_API_KEY
export HV_EVIDENCE=$EVD HV_HERMES_IMAGE=hv-hermes:spike
trap '"$SK/hv-hermes-env.sh" down orb >/dev/null 2>&1' EXIT

# les `sleep 303` du conteneur : la commande approuvée en lance un, dans sa propre session
# un `docker exec` en échec n'est pas « 0 processus » : il ferait passer Non sans rien avoir lu
detached() { local ps; ps=$(docker exec "$CT" ps -eo args) || return 1; grep -c '^sleep 303$' <<<"$ps" || true; }
# chaque appel doit réussir : un échec arrête la lane avant tout RESULT OK
die() { say "RESULT FAIL : $*"; exit 1; }
{
  say "code $(git -C "$REPO" rev-parse --short HEAD), $(sw_vers -productName) $(sw_vers -productVersion)"
  "$SK/hv-guard.sh" target "$CT" || exit 1
  "$SK/hv-guard.sh" snapshot "$EVD/guard-before.txt" || exit $?
  "$SK/hv-hermes-env.sh" up orb || { say "ORB FAIL : up a échoué"; exit 1; }
  say "version Hermes lue sur /health : $(curl -fsS -m 3 "$URL/health" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"
  BEFORE=$(detached) || die "docker exec a échoué avant Non"; say "sleep 303 dans le conteneur avant : $BEFORE"
  echo "================ Non : approve avec deny"
  DENY_OUT=$("$PROBE" approve --url "$URL" --profile hv-bot-a --input 'HV_TOOL_DETACH go' --choice deny); RC=$?; echo "$DENY_OUT"
  [ "$RC" = 0 ] || die "approve deny a échoué (code $RC)"
  DENY_RUN=$(sed -n 's/^run: //p' <<<"$DENY_OUT" | head -1)
  [ -n "$DENY_RUN" ] || die "approve deny n'a pas écrit de run"
  echo "---------------- l'état final du tour refusé"
  DENY_TURN=$("$PROBE" read-turn --url "$URL" --profile hv-bot-a --run "$DENY_RUN" --timeout 60); RC=$?; echo "$DENY_TURN"
  [ "$RC" = 0 ] || die "read-turn du tour refusé a échoué (code $RC)"
  DENY_STATE=$(sed -n 's/^state: //p' <<<"$DENY_TURN" | head -1)
  [ "$DENY_STATE" = completed ] || die "le tour refusé finit à l'état « ${DENY_STATE:-absent} », completed attendu"
  sleep 3
  AFTER_DENY=$(detached) || die "docker exec a échoué après Non"; say "sleep 303 dans le conteneur après Non : $AFTER_DENY"
  echo "================ Oui : approve avec once"
  YES_OUT=$("$PROBE" approve --url "$URL" --profile hv-bot-a --input 'HV_TOOL_DETACH go' --choice once); RC=$?; echo "$YES_OUT"
  [ "$RC" = 0 ] || die "approve once a échoué (code $RC)"
  sleep 3
  AFTER_YES=$(detached) || die "docker exec a échoué après Oui"; say "sleep 303 dans le conteneur après Oui : $AFTER_YES"
  echo "---------------- processus du conteneur après Oui"
  docker exec "$CT" ps -eo pid,args | grep -E 'sleep|python3 -c' | grep -v grep || true
  echo "================ garde des chemins protégés"
  "$SK/hv-guard.sh" check "$EVD/guard-before.txt"; GUARD=$?
  echo "================ verdict"
  say "avant : $BEFORE, après Non : $AFTER_DENY, après Oui : $AFTER_YES ; Non : $(sed -n 's/^approved: //p' <<<"$DENY_OUT"), état $DENY_STATE ; Oui : $(sed -n 's/^approved: //p' <<<"$YES_OUT")"
  # le nom de l'outil que la feuille montre : approval.request n'en porte pas, il vient du tool.started qui le précède
  TOOL=$(sed -n 's/^approval: [0-9a-f]* generation=[^ ]* tool=\([^ ]*\) .*/\1/p' <<<"$YES_OUT" | head -1); say "outil nommé par la demande : ${TOOL:-aucun}"
  if [ "$BEFORE" = 0 ] && [ "$AFTER_DENY" = 0 ] && [ "$TOOL" = terminal ] && [ "$AFTER_YES" -ge 1 ] && grep -q 'choice=deny resolved=true' <<<"$DENY_OUT" && grep -q 'choice=once resolved=true' <<<"$YES_OUT" && [ "$GUARD" = 0 ]; then
    say "RESULT OK : Oui lance l'outil dans le conteneur, Non ne le lance pas, chaque décision est prise une fois"
  else
    say "RESULT FAIL"
  fi
} 2>&1 | tee "$LOG"
LANE_RC=${PIPESTATUS[0]}

if grep -qF "$HV_TEST_API_KEY" "$LOG"; then echo "SECRET dans le journal : arrêt" >&2; exit 1; fi
{
  echo "HD-11 lane 9 code=$(git -C "$REPO" rev-parse --short HEAD) rendu=$(TZ=Europe/Paris date '+%Y-%m-%d %H:%M:%S') Paris"
  echo "Transcription de terminal rendue en image, pas une capture de l'app : l'app ne tourne pas contre OrbStack (vm.sh ui orb : HV-UI SAUTÉE)"
  echo
  fold -w 118 -s "$LOG"
} > "$EVD/render.txt"
magick -background '#1e1e1e' -fill '#e6e6e6' -font /System/Library/Fonts/Menlo.ttc -pointsize 15 "label:@$EVD/render.txt" -bordercolor '#1e1e1e' -border 16 "$PNG"
echo "PNG $PNG, journal $LOG"
[ "$LANE_RC" = 0 ] && grep -q "RESULT OK" "$LOG"
