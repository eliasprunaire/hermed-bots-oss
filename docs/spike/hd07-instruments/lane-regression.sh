#!/usr/bin/env bash
# lane-regression.sh <dossier-de-preuves> : lane 1, le même test de lancement au trunk (connexion directe) puis au head (tunnel)
# Au trunk, l'app se connecte droit à 127.0.0.1:18642 (le port publié par le conteneur) ; au head, elle ne reçoit aucune adresse d'API et passe par le tunnel
# HV_XCTESTRUN_TRUNK et HV_XCTESTRUN : fichiers .xctestrun du trunk et du head
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: lane-regression.sh <dossier-de-preuves>}
mkdir -p "$EVD"
TRUNK_RUN=${HV_XCTESTRUN_TRUNK:-$(ls "$HVW"/dd-trunk/Build/Products/*.xctestrun | head -1)}
say "trunk $(git -C "$HVW/trunk-wt" rev-parse --short HEAD), head $(git -C "$REPO" rev-parse --short HEAD)"
say "1. trunk : LaunchTests contre 127.0.0.1:18642, connexion directe"
TEST_RUNNER_HV_TEST_MODE=1 TEST_RUNNER_HV_API_URL=http://127.0.0.1:18642 TEST_RUNNER_HV_SHOTS="$EVD/trunk-shots" \
  xcodebuild test-without-building -xctestrun "$TRUNK_RUN" -destination 'platform=macOS' \
  -only-testing:HermedBotsUITests/LaunchTests/testWindowOpensWithTheServerVersionAndAnEmptyBotList \
  -resultBundlePath "$EVD/trunk.xcresult" > "$EVD/trunk.log" 2>&1; rc_t=$?
grep -E "HV-LAUNCH|HV-SHOT|Test Case .*(passed|failed)|Executed [0-9]+ tests" "$EVD/trunk.log" | sed -E 's/\(.*\) *$//' | sort -u
say "trunk rc=$rc_t"
say "2. head : TunnelTests, la même version doit sortir du tunnel"
"$HERE/run-ui.sh" "$EVD/head" testTheVersionComesThroughTheTunnelNotThroughTheDirectPort; rc_h=$?
say "head rc=$rc_h"
"$SK/hv-shotdiff.sh" --export "$EVD/head/result.xcresult" "$EVD/head/shots" hd07-tunnel | tail -1
"$SK/hv-shotdiff.sh" --export "$EVD/trunk.xcresult" "$EVD/trunk-shots" launch | tail -1
t=$(grep -m1 -o 'hd.status.version=[0-9.]*' "$EVD/trunk.log" | cut -d= -f2)
h=$(grep -m1 -o 'HV-TUNNEL version=[0-9.]*' "$EVD/head/xcodebuild.log" | cut -d= -f2)
say "version lue au trunk : $t ; au head : $h"
if [ -n "$t" ] && [ "$t" = "$h" ] && [ $rc_t -eq 0 ] && [ $rc_h -eq 0 ]; then say "RESULT OK : même version, le head passe par le tunnel"; exit 0; fi
say "RESULT FAIL"; exit 1
