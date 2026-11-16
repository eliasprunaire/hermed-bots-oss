#!/usr/bin/env bash
# hv-netwatch.sh — relève les connexions sortantes de l'app pendant une passe. Modèle : aucun
# Usage : hv-netwatch.sh <pid-app> <durée-s> <sortie.txt> [ports-autorisés="18642 22"]
# Échantillonne `lsof -nP -iTCP -iUDP -a -p PID` chaque seconde (et `nettop -P -L 1 -p PID`
# si disponible, macOS). Toute destination hors 127.0.0.1/::1 sur un port autorisé = violation
# Codes : 0 aucune connexion interdite ; 2 usage ; 14 connexion interdite vue ; 15 lsof absent
set -euo pipefail
PATH="$PATH:/usr/sbin"  # lsof est dans /usr/sbin, absent du PATH du lanceur le planificateur du lanceur
[ $# -ge 3 ] || { echo "usage: $0 <pid> <durée> <sortie> [ports]" >&2; exit 2; }
PID=$1; DUR=$2; OUT=$3; PORTS=${4:-"18642 22"}
command -v lsof >/dev/null 2>&1 || { echo "NET FAIL (15): lsof absent" >&2; exit 15; }
: > "$OUT"; i=0
while [ "$i" -lt "$DUR" ]; do
  lsof -nP -iTCP -iUDP -a -p "$PID" 2>/dev/null | awk 'NR>1' >> "$OUT" || true
  if command -v nettop >/dev/null 2>&1; then nettop -P -L 1 -p "$PID" >> "$OUT.nettop" 2>/dev/null || true; fi
  sleep 1; i=$((i+1))
done
bad=0
while read -r line; do
  peer=$(printf '%s\n' "$line" | grep -oE -- '->[^ ]+' | sed 's/^->//' || true)
  [ -n "$peer" ] || continue
  host=${peer%:*}; port=${peer##*:}
  case "$host" in 127.0.0.1|\[::1\]|localhost) ok=0; for p in $PORTS; do [ "$p" = "$port" ] && ok=1; done ;;
    *) ok=0 ;; esac
  [ "$ok" = 1 ] || { echo "NET VIOLATION: $peer"; bad=1; }
done < "$OUT"
[ "$bad" = 0 ] && echo "NET OK: aucune connexion hors $PORTS sur localhost" || exit 14
