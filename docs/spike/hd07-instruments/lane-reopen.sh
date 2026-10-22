#!/usr/bin/env bash
# lane-reopen.sh <dossier-de-preuves> kill|network : coupe le tunnel d'une app lancée à la main, puis regarde s'il se rouvre seul
#   kill    : lane 3, SIGKILL du ssh enfant en pleine session
#   network : lane 9, docker network disconnect bridge hv-hermes-test, 30 s de coupure, puis reconnexion
# Écrit <dossier>/<mode>-before.png, <mode>-during.png, <mode>-after.png (fenêtre de l'app) et un journal sur la sortie standard
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: lane-reopen.sh <dossier> kill|network}; MODE=${2:?kill|network}
mkdir -p "$EVD"
new_keys || exit 1
sshd_before=$(sshd_accepts)
start_app "$EVD/app-$MODE.log"
trap 'stop_app "$APP_PID"' EXIT
say "app pid=$APP_PID, tunnel demandé vers $SSH_HOST"

# le tunnel s'ouvre
S1=
for _ in $(seq 1 60); do S1=$(ssh_child "$APP_PID"); [ -n "$S1" ] && [ -n "$(tunnel_port "$S1")" ] && curl -fsS -m 2 "http://127.0.0.1:$(tunnel_port "$S1")/health" >/dev/null 2>&1 && break; sleep 0.5; done
[ -n "$S1" ] || { say "FAIL: aucun ssh enfant de l'app"; exit 1; }
P1=$(tunnel_port "$S1")
say "tunnel ouvert : ssh pid=$S1, port local $P1, groupe $(ps -o pgid= -p "$S1" | tr -d ' ')"
say "GET /health par le tunnel : $(curl -sS -m 3 "http://127.0.0.1:$P1/health")"
sleep 1.5
window_png "$APP_PID" "$EVD/$MODE-before.png"
say "accès sshd avant la coupure : $(( $(sshd_accepts) - sshd_before ))"

if [ "$MODE" = kill ]; then
  say "kill -KILL $S1 (le ssh enfant)"
  kill -KILL "$S1"
else
  say "docker network disconnect bridge hv-hermes-test"
  docker network disconnect bridge hv-hermes-test
  T0=$(date +%s)
fi

# pendant la coupure : une ligne par seconde (ssh enfant, tunnel qui répond ; aucune sonde ne résout le nom du conteneur, la résolution bloque tant qu'il est détaché), et la fenêtre quand le bandeau doit être visible
if [ "$MODE" = kill ]; then span=${DURING:-6}; else span=28; fi
for i in $(seq 1 "$span"); do
  sleep 1
  cur=$(ssh_child "$APP_PID"); cp=
  [ -n "$cur" ] && cp=$(tunnel_port "$cur")
  say "t+${i}s ssh enfant='$cur' port='$cp' tunnel=$([ -n "$cp" ] && curl -fsS -m 1 "http://127.0.0.1:$cp/health" >/dev/null 2>&1 && echo répond || echo muet)"
  if [ "$MODE" = network ] && [ "$i" = 22 ]; then window_png "$APP_PID" "$EVD/$MODE-during.png"; fi
done
[ "$MODE" = kill ] && window_png "$APP_PID" "$EVD/$MODE-during.png"

if [ "$MODE" = network ]; then
  # 30 s de coupure en tout
  rest=$(( 30 - ($(date +%s) - T0) )); [ "$rest" -gt 0 ] && sleep "$rest"
  say "docker network connect bridge hv-hermes-test (après $(( $(date +%s) - T0 )) s de coupure)"
  docker network connect bridge hv-hermes-test
  T1=$(date +%s)
fi

# la réouverture : un autre ssh, un autre port local, sans aucune action de l'utilisateur
S2=
for _ in $(seq 1 90); do
  S2=$(ssh_child "$APP_PID")
  if [ -n "$S2" ] && [ "$S2" != "$S1" ] && [ -n "$(tunnel_port "$S2")" ] && curl -fsS -m 2 "http://127.0.0.1:$(tunnel_port "$S2")/health" >/dev/null 2>&1; then break; fi
  S2=; sleep 0.5
done
if [ -z "$S2" ]; then say "FAIL: le tunnel ne s'est pas rouvert"; exit 1; fi
P2=$(tunnel_port "$S2")
[ "$MODE" = network ] && say "tunnel rouvert $(( $(date +%s) - T1 )) s après la reconnexion réseau"
say "tunnel rouvert : ssh pid=$S2 (avant $S1), port local $P2 (avant $P1), groupe $(ps -o pgid= -p "$S2" | tr -d ' ')"
say "action suivante, GET /health par le nouveau tunnel : $(curl -sS -m 3 "http://127.0.0.1:$P2/health")"
sleep 2  # l'app relit la version toute seule à la réouverture
window_png "$APP_PID" "$EVD/$MODE-after.png"
say "accès sshd au total depuis le début : $(( $(sshd_accepts) - sshd_before ))"
say "app vivante à la fin : $(kill -0 "$APP_PID" 2>/dev/null && echo oui || echo NON)"
[ "$MODE" = network ] && say "port publié 127.0.0.1:18642 après reconnexion : $(curl -sS -m 3 http://127.0.0.1:18642/health || echo injoignable)"
say "RESULT OK"
