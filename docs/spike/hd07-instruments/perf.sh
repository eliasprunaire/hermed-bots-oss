#!/usr/bin/env bash
# perf.sh <dossier-de-preuves> [nombre] : du lancement à la première réponse de l'API, trunk (connexion directe) contre head (tunnel)
# Lance `nombre` (5) mesures de chaque côté, en alternance trunk, head, trunk, head, contre hv-hermes-test
# Chaque mesure est un lancement à froid par XCUITest (ColdLaunchProbe) : elle part de app.launch() et s'arrête quand hd.status.version montre la version
# HV_XCTESTRUN_TRUNK et HV_XCTESTRUN : fichiers .xctestrun du trunk et du head, construits avec derivedData séparés
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: perf.sh <dossier-de-preuves> [nombre]}; N=${2:-5}
mkdir -p "$EVD"
TRUNK_RUN=${HV_XCTESTRUN_TRUNK:-$(ls "$HVW"/dd-trunk/Build/Products/*.xctestrun | head -1)}
HEAD_RUN=${HV_XCTESTRUN:-$(ls "$HVW"/dd/Build/Products/*.xctestrun | head -1)}
new_alias || exit 1
trap drop_alias EXIT
: > "$EVD/perf.txt"
one() { # $1 trunk|head, $2 numéro
  local run rc
  if [ "$1" = trunk ]; then run=$TRUNK_RUN; else run=$HEAD_RUN; fi
  if [ "$1" = trunk ]; then
    TEST_RUNNER_HV_API_URL=http://127.0.0.1:18642 xcodebuild test-without-building -xctestrun "$run" -destination 'platform=macOS' \
      -only-testing:HermedBotsUITests/ColdLaunchProbe -resultBundlePath "$EVD/$1-$2.xcresult" > "$EVD/$1-$2.log" 2>&1
  else
    TEST_RUNNER_HV_SSH_HOST=${HV_SSH_ALIAS:-$SSH_ALIAS} \
      xcodebuild test-without-building -xctestrun "$run" -destination 'platform=macOS' \
      -only-testing:HermedBotsUITests/ColdLaunchProbe -resultBundlePath "$EVD/$1-$2.xcresult" > "$EVD/$1-$2.log" 2>&1
  fi
  rc=$?
  local line; line=$(grep -m1 'HV-PERF07' "$EVD/$1-$2.log" || echo "HV-PERF07 mode=? ms=ÉCHEC")
  echo "$1 $2 rc=$rc $line" | tee -a "$EVD/perf.txt"
}
for i in $(seq 1 "$N"); do one trunk "$i"; one head "$i"; done
python3 -I "$HERE/perf-summary.py" "$EVD/perf.txt" "$N"
