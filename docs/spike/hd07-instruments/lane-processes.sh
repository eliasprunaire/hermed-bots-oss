#!/usr/bin/env bash
# lane-processes.sh <dossier-de-preuves> <test ...> : lance les tests UI pendant que la table des processus du tunnel est échantillonnée
# Le runner XCUITest est sandboxé et ne peut pas lancer ps : ce script le fait à sa place, toutes les 0,2 s
# Sert aux lanes 4 (aucun orphelin après avoir quitté) et 8 (aucun ssh pour un hôte refusé)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: lane-processes.sh <dossier-de-preuves> <test ...>}; shift
mkdir -p "$EVD"
SAMPLES=$EVD/ps-samples.txt
: > "$SAMPLES"
# l'échantillonneur retient `/usr/bin/ssh` de l'app (`-G -vv` et le tunnel) et le gardien : pas les sessions `vssh`
(
  while :; do
    t=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    printf '%s TICK\n' "$t" >> "$SAMPLES"
    ps -Ao pgid=,pid=,ppid=,args= | grep -E '/usr/bin/ssh |while read -r _; do :; done' | grep -v grep | sed "s/^/$t /" >> "$SAMPLES"
    sleep 0.2
  done
) &
SAMPLER=$!
"$HERE/run-ui.sh" "$EVD" "$@"; rc=$?
sleep 3  # derniers échantillons, app fermée
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
python3 "$HERE/summarize-samples.py" "$SAMPLES"; src=$?
[ $rc -eq 0 ] && rc=$src
if printf '%s' "$*" | grep -q 'testAPersoHermesHostInTheEnvironmentNeverStartsSsh'; then
  if grep -E '/usr/bin/ssh ' "$SAMPLES" >/dev/null; then
    echo "RESULT FAIL : /usr/bin/ssh vu pendant le refus de l'hote interdit en mode test"
    rc=1
  fi
fi
exit $rc
