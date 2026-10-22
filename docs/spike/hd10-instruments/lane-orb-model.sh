#!/usr/bin/env bash
# lane-orb-model.sh <sortie.png> : lane 5 de HD-10, changer le modèle d'une session de hv-bot-a sur hv-hermes-test
# L'app ne tourne pas contre OrbStack : la VM de la passe UI n'atteint pas l'hôte (`vm.sh ui orb` rend « HV-UI SAUTÉE »), et l'app ne se lance jamais sur l'hôte
# Cette lane rejoue donc, avec hd-probe et HermesClient, les appels que ConversationModel fait : new_session, set_model, list_sessions, start_run avec session_id et model, run_events
# Pass : la réponse du tour suivant nomme le modèle choisi (S4), une session sans choix garde le modèle du profil, la liste des fils porte le modèle du verrou, config.yaml du profil est inchangé
# Le script montre aussi pourquoi l'app met `model` dans chaque run : sans lui, `POST /v1/runs` ignore le verrou (route_source global)
# Le PNG est une transcription de terminal rendue en image, pas une capture de l'app
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
SK=$REPO/.cursor/skills/verify-hermed-bots/scripts
PNG=${1:?usage: lane-orb-model.sh <sortie.png>}
WORK=${HV_WORK:-$HOME/hermed-bots-work}
EVD=$WORK/evidence/hd10-orb-$(TZ=Europe/Paris date +%Y%m%d-%H%M%S)
mkdir -p "$EVD"
LOG=$EVD/lane.log
URL=http://127.0.0.1:18642
CT=hv-hermes-test
CFG=/opt/data/profiles/hv-bot-a/config.yaml
say() { printf '[%s Paris] %s\n' "$(TZ=Europe/Paris date +%H:%M:%S)" "$*"; }

(cd "$REPO/Packages/HermesAdapter" && swift build --product hd-probe 2>&1 | tail -1) || exit 1
PROBE=$REPO/Packages/HermesAdapter/.build/debug/hd-probe

# la clé de test se tire au hasard, reste dans l'environnement de ce script et n'est jamais affichée
HV_TEST_API_KEY=$(openssl rand -hex 16); export HV_TEST_API_KEY
export HV_EVIDENCE=$EVD HV_HERMES_IMAGE=hv-hermes:spike
trap '"$SK/hv-hermes-env.sh" down orb >/dev/null 2>&1' EXIT

reply() { grep '^text: ' | head -1; }
{
  say "code $(git -C "$REPO" rev-parse --short HEAD), $(sw_vers -productName) $(sw_vers -productVersion)"
  "$SK/hv-guard.sh" target "$CT" || exit 1
  "$SK/hv-guard.sh" snapshot "$EVD/guard-before.txt" || exit $?
  "$SK/hv-hermes-env.sh" up orb || { say "ORB FAIL : up a échoué"; exit 1; }
  say "version Hermes lue sur /health : $(curl -fsS -m 3 "$URL/health" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"
  CFG_BEFORE=$(docker exec "$CT" sha256sum "$CFG" | cut -d' ' -f1)
  say "config.yaml du profil avant : sha256 $CFG_BEFORE, $(docker exec "$CT" grep -m1 'default:' "$CFG" | sed 's/^ *//')"
  echo "================ new_session"
  SESSION=$("$PROBE" new-session --url "$URL" --profile hv-bot-a | sed -n 's/^session: //p'); echo "session: $SESSION"
  echo "================ list_sessions, avant le choix"
  "$PROBE" list-sessions --url "$URL" --profile hv-bot-a --session "$SESSION" | grep session-model
  echo "================ set_model hv-fake-2 sur cette session"
  "$PROBE" set-model --url "$URL" --profile hv-bot-a --session "$SESSION" --model hv-fake-2
  echo "================ list_sessions, après le choix"
  "$PROBE" list-sessions --url "$URL" --profile hv-bot-a --session "$SESSION" | grep session-model; LISTED=$("$PROBE" list-sessions --url "$URL" --profile hv-bot-a --session "$SESSION" | sed -n 's/^session-model: //p')
  echo "================ start_run avec session_id sans model (ce que HD-09 faisait) : Hermes ignore le verrou"
  WITHOUT=$("$PROBE" read-turn --url "$URL" --profile hv-bot-a --session "$SESSION" --input "sans model" | reply); echo "$WITHOUT"
  echo "================ start_run avec session_id et model hv-fake-2 (ce que HD-10 fait)"
  WITH=$("$PROBE" read-turn --url "$URL" --profile hv-bot-a --session "$SESSION" --input "avec model" --model hv-fake-2 | reply); echo "$WITH"
  echo "================ une autre session de hv-bot-a, sans choix : le modèle du profil"
  OTHER=$("$PROBE" new-session --url "$URL" --profile hv-bot-a | sed -n 's/^session: //p'); echo "session: $OTHER"
  PLAIN=$("$PROBE" read-turn --url "$URL" --profile hv-bot-a --session "$OTHER" --input "autre session" | reply); echo "$PLAIN"
  echo "================ config.yaml du profil après"
  CFG_AFTER=$(docker exec "$CT" sha256sum "$CFG" | cut -d' ' -f1); echo "sha256 $CFG_AFTER, $(docker exec "$CT" grep -m1 'default:' "$CFG" | sed 's/^ *//')"
  echo "================ garde des chemins protégés"
  "$SK/hv-guard.sh" check "$EVD/guard-before.txt"; GUARD=$?
  echo "================ verdict"
  say "session verrouillée : liste=$LISTED, tour sans model : ${WITHOUT#text: }, tour avec model : ${WITH#text: }, autre session : ${PLAIN#text: }"
  if [ "$LISTED" = hv-fake-2 ] && [[ "$WITH" == *"model=hv-fake-2"* ]] && [[ "$WITHOUT" == *"model=hv-fake-1"* ]] && [[ "$PLAIN" == *"model=hv-fake-1"* ]] && [ "$CFG_BEFORE" = "$CFG_AFTER" ] && [ "$GUARD" = 0 ]; then
    say "RESULT OK : la réponse du tour suivant vient du modèle choisi, une autre session et le profil gardent hv-fake-1, la liste porte le modèle du verrou, config.yaml est inchangé"
  else
    say "RESULT FAIL"
  fi
} 2>&1 | tee "$LOG"

if grep -qF "$HV_TEST_API_KEY" "$LOG"; then echo "SECRET dans le journal : arrêt" >&2; exit 1; fi
{
  echo "HD-10 lane 5 code=$(git -C "$REPO" rev-parse --short HEAD) rendu=$(TZ=Europe/Paris date '+%Y-%m-%d %H:%M:%S') Paris"
  echo "Transcription de terminal rendue en image, pas une capture de l'app : l'app ne tourne pas contre OrbStack (vm.sh ui orb : HV-UI SAUTÉE)"
  echo
  fold -w 118 -s "$LOG"
} > "$EVD/render.txt"
magick -background '#1e1e1e' -fill '#e6e6e6' -font /System/Library/Fonts/Menlo.ttc -pointsize 15 "label:@$EVD/render.txt" -bordercolor '#1e1e1e' -border 16 "$PNG"
echo "PNG $PNG, journal $LOG"
grep -q "RESULT OK" "$LOG"
