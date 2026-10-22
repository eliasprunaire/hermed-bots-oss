#!/usr/bin/env bash
# netsample.sh <sortie> <fichier-d'arrêt> : lance lsof sur l'app et ses enfants tous les 0,3 s jusqu'à ce que le fichier d'arrêt existe
# Chaque ligne de sortie : commande, pid, nom lsof (adresse locale et destination). Sert à la lane 10 : la liste de toutes les destinations vues
# Un processus est de l'app s'il se nomme HermedBots, ou s'il en est l'enfant direct (ssh, ssh-agent)
set -uo pipefail
export PATH="$PATH:/usr/sbin"
OUT=${1:?usage: netsample.sh <sortie> <fichier-d-arret>}; STOP=${2:?}
: > "$OUT"
while [ ! -e "$STOP" ]; do
  apps=$(pgrep -x HermedBots | tr '\n' ' ')
  if [ -n "$apps" ]; then
    pids=$(ps -Ao pid=,ppid= | awk -v a="$apps" 'BEGIN { n = split(a, list, " "); for (i = 1; i <= n; i++) app[list[i]] = 1 } ($1 in app) || ($2 in app) { printf "%s%s", sep, $1; sep = "," }')
    [ -n "$pids" ] && lsof -nP -iTCP -iUDP -a -p "$pids" 2>/dev/null | awk 'NR > 1 { print $1, $2, $9, $10 }' >> "$OUT"
  fi
  sleep 0.3
done
