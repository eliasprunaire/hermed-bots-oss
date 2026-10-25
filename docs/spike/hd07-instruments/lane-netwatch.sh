#!/usr/bin/env bash
# lane-netwatch.sh <dossier-de-preuves> : lane 6, la seule connexion sortante d'une session est le tunnel
# Lance l'app à la main, puis hv-netwatch.sh sur l'app et sur son ssh pendant 14 s, avec un échantillonnage lsof plus fin
# hv-netwatch.sh ne tient pour permise qu'une destination 127.0.0.1 ou ::1 : le ssh se connecte au conteneur, donc ce script le signale
# par construction. La preuve est la liste brute des paires (processus, destination) : seule la destination du tunnel apparaît hors boucle locale
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: lane-netwatch.sh <dossier-de-preuves>}
mkdir -p "$EVD"
new_alias || exit 1
trap drop_alias EXIT
# le nom .host.example donne une adresse d'OrbStack, pas celle du réseau bridge de docker
CONTAINER_IP=$(python3 -c "import socket; print(socket.gethostbyname('$SSH_HOST'))")
say "$SSH_HOST se résout en $CONTAINER_IP (la destination du tunnel)"
start_app "$EVD/app-netwatch.log"
trap 'stop_app "$APP_PID"; drop_alias' EXIT
# échantillonnage fin des sockets de toute la famille de l'app (app, gardien, agent, ssh), dès le lancement
: > "$EVD/lsof-all.txt"
(
  while kill -0 "$APP_PID" 2>/dev/null; do
    pids=$(ps -Ao pid=,ppid= | awk -v a="$APP_PID" '$1==a || $2==a {printf "%s%s", sep, $1; sep=","}')
    [ -n "$pids" ] && lsof -nP -iTCP -iUDP -a -p "$pids" 2>/dev/null | awk 'NR>1 {print $1, $2, $5, $8, $9, $10}' >> "$EVD/lsof-all.txt"
    sleep 0.2
  done
) &
SAMPLER=$!
for _ in $(seq 1 40); do S=$(ssh_child "$APP_PID"); [ -n "$S" ] && P=$(tunnel_port "$S") && [ -n "$P" ] && break; sleep 0.25; done
say "tunnel ouvert : ssh pid $S, port local $P"
say "hv-netwatch.sh sur l'app (pid $APP_PID), 7 s : seul 127.0.0.1:$P est permis"
"$SK/hv-netwatch.sh" "$APP_PID" 7 "$EVD/net-app.txt" "$P" > "$EVD/netwatch-app.out" 2>&1 &
NW1=$!
say "hv-netwatch.sh sur le ssh enfant (pid $S), 7 s : seul le port 22 est permis"
"$SK/hv-netwatch.sh" "$S" 7 "$EVD/net-ssh.txt" "22" > "$EVD/netwatch-ssh.out" 2>&1 &
NW2=$!
sleep 8
# du trafic de l'app dans la session : on coupe le ssh, le tunnel se rouvre, l'app relit la version par le nouveau port
say "kill -KILL $S : le tunnel se rouvre, l'app relit la version"
kill -KILL "$S"
for _ in $(seq 1 40); do S2=$(ssh_child "$APP_PID"); [ -n "$S2" ] && [ "$S2" != "$S" ] && P2=$(tunnel_port "$S2") && [ -n "$P2" ] && break; sleep 0.25; done
say "tunnel rouvert : ssh pid $S2, port local $P2"
say "hv-netwatch.sh sur l'app (pid $APP_PID), 7 s : seul 127.0.0.1:$P2 est permis"
"$SK/hv-netwatch.sh" "$APP_PID" 7 "$EVD/net-app2.txt" "$P2" > "$EVD/netwatch-app2.out" 2>&1 &
NW1B=$!
say "hv-netwatch.sh sur le nouveau ssh (pid $S2), 7 s"
"$SK/hv-netwatch.sh" "$S2" 7 "$EVD/net-ssh2.txt" "22" > "$EVD/netwatch-ssh2.out" 2>&1 &
NW3=$!
wait "$NW1"; rc1=$?; wait "$NW1B"; rc1b=$?; wait "$NW2"; rc2=$?; wait "$NW3"; rc3=$?
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
say "--- hv-netwatch.sh sur l'app : code $rc1 puis $rc1b après la réouverture"; cat "$EVD/netwatch-app.out" "$EVD/netwatch-app2.out"
say "--- hv-netwatch.sh sur le ssh : code $rc2 ; sur le nouveau ssh : code $rc3 (14 attendu : leur destination est le conteneur, pas 127.0.0.1)"; cat "$EVD/netwatch-ssh.out" "$EVD/netwatch-ssh2.out"
say "--- paires (commande, destination) vues par lsof pendant toute la session, sans doublon"
awk '{print $1, $4, $5, $6}' "$EVD/lsof-all.txt" | sed -E 's/\(([A-Z_]+)\)/\1/' | sort | uniq -c | sort -rn
echo
# toute destination qui n'est ni 127.0.0.1 ni le conteneur est une connexion sortante en trop
others=$(grep -oE -- '->[^ ]+' "$EVD/lsof-all.txt" | sed 's/^->//' | grep -vE '^127\.0\.0\.1:|^\[::1\]:' | grep -v "^$CONTAINER_IP:22$" | sort -u)
tunnel_peers=$(grep -oE -- "->$CONTAINER_IP:22" "$EVD/lsof-all.txt" | sort -u)
say "destinations hors boucle locale : $(grep -oE -- '->[^ ]+' "$EVD/lsof-all.txt" | sed 's/^->//' | grep -vE '^127\.0\.0\.1:|^\[::1\]:' | sort -u | tr '\n' ' ')"
say "destinations autres que le tunnel ($CONTAINER_IP:22) : ${others:-aucune}"
if [ -n "$tunnel_peers" ] && [ -z "$others" ] && [ "$rc1" -eq 0 ] && [ "$rc1b" -eq 0 ]; then say "RESULT OK : la seule connexion sortante est le tunnel vers $CONTAINER_IP:22"; exit 0; fi
say "RESULT FAIL"; exit 1
