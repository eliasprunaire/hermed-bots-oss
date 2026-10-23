#!/usr/bin/env bash
# lane-orb-send.sh <sortie.png> : lane 2 de HD-09, un message à hv-bot-a sur hv-hermes-test
# L'app ne tourne pas contre OrbStack : la VM de la passe UI n'atteint pas l'hôte (`<vm-test-script> ui orb` rend « HV-UI SAUTÉE »), et l'app ne se lance jamais sur l'hôte
# Cette lane rejoue donc, avec hd-probe et HermesClient, les appels que ConversationModel fait : new_session, start_run avec session_id, run_events, session_messages
# Pass : l'état est completed, la réponse est celle du faux fournisseur, et le transcript du fil de Hermes garde le message une fois
# Le PNG est une transcription de terminal rendue en image, pas une capture de l'app
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
SK=$REPO/.cursor/skills/verify-hermed-bots/scripts
PNG=${1:?usage: lane-orb-send.sh <sortie.png>}
WORK=${HV_WORK:-$HOME/hermed-bots-work}
EVD=$WORK/evidence/hd09-orb-$(TZ=Europe/Paris date +%Y%m%d-%H%M%S)
mkdir -p "$EVD"
LOG=$EVD/lane.log
URL=http://127.0.0.1:18642
TEXT="bonjour hd09"
say() { printf '[%s Paris] %s\n' "$(TZ=Europe/Paris date +%H:%M:%S)" "$*"; }

(cd "$REPO/Packages/HermesAdapter" && swift build --product hd-probe 2>&1 | tail -1) || exit 1
PROBE=$REPO/Packages/HermesAdapter/.build/debug/hd-probe

# la clé de test se tire au hasard, reste dans l'environnement de ce script et n'est jamais affichée
HV_TEST_API_KEY=$(openssl rand -hex 16); export HV_TEST_API_KEY
export HV_EVIDENCE=$EVD HV_HERMES_IMAGE=hv-hermes:spike
trap '"$SK/hv-hermes-env.sh" down orb >/dev/null 2>&1' EXIT

{
  say "code $(git -C "$REPO" rev-parse --short HEAD), $(sw_vers -productName) $(sw_vers -productVersion)"
  "$SK/hv-hermes-env.sh" up orb || { say "ORB FAIL : up a échoué"; exit 1; }
  say "version Hermes lue sur /health : $(curl -fsS -m 3 "$URL/health" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"
  echo "================ new_session"
  SESSION=$("$PROBE" new-session --url "$URL" --profile hv-bot-a | sed -n 's/^session: //p')
  echo "session: $SESSION"
  echo "================ start_run avec session_id, puis run_events"
  "$PROBE" read-turn --url "$URL" --profile hv-bot-a --session "$SESSION" --input "$TEXT" | grep -v '^approval:'; STATE_RC=${PIPESTATUS[0]}
  echo "================ session_messages"
  TRANSCRIPT=$("$PROBE" messages --url "$URL" --profile hv-bot-a --session "$SESSION")
  echo "$TRANSCRIPT"
  echo "================ list_sessions"
  "$PROBE" list-sessions --url "$URL" --profile hv-bot-a
  echo "================ verdict"
  USER_LINES=$(printf '%s\n' "$TRANSCRIPT" | grep -c " user $TEXT\$")
  REPLY_LINES=$(printf '%s\n' "$TRANSCRIPT" | grep -c " assistant HV-FAKE-REPLY")
  say "read-turn rc=$STATE_RC, lignes user '$TEXT' dans le fil : $USER_LINES, lignes de réponse du faux fournisseur : $REPLY_LINES"
  if [ "$STATE_RC" = 0 ] && [ "$USER_LINES" = 1 ] && [ "$REPLY_LINES" = 1 ]; then say "RESULT OK : la réponse est là et le fil de Hermes garde le message une fois"; else say "RESULT FAIL"; fi
} 2>&1 | tee "$LOG"

if grep -qF "$HV_TEST_API_KEY" "$LOG"; then echo "SECRET dans le journal : arrêt" >&2; exit 1; fi
{
  echo "HD-09 lane 2 code=$(git -C "$REPO" rev-parse --short HEAD) rendu=$(TZ=Europe/Paris date '+%Y-%m-%d %H:%M:%S') Paris"
  echo "Transcription de terminal rendue en image, pas une capture de l'app : l'app ne tourne pas contre OrbStack (<vm-test-script> ui orb : HV-UI SAUTÉE)"
  echo
  fold -w 118 -s "$LOG"
} > "$EVD/render.txt"
magick -background '#1e1e1e' -fill '#e6e6e6' -font /System/Library/Fonts/Menlo.ttc -pointsize 15 "label:@$EVD/render.txt" -bordercolor '#1e1e1e' -border 16 "$PNG"
echo "PNG $PNG, journal $LOG"
grep -q "RESULT OK" "$LOG"
