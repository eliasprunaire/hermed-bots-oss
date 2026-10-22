#!/usr/bin/env bash
# run-ui.sh <dossier-de-preuves> [test ...] : lance les tests UI du tunnel contre hv-hermes-test
# Le conteneur doit déjà tourner (hv-ssh-endpoint.sh up). Les clés de test sont tirées ici et ne touchent pas le dossier de preuves
# HV_XCTESTRUN : fichier .xctestrun de build-for-testing ; HV_FILTER : -only-testing, par défaut tous les TunnelTests
# hv-run.sh ne transmet ni HV_SSH_HOST ni les clés SSH au runner de tests : ce script fait cet appel à sa place
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: run-ui.sh <dossier-de-preuves> [test ...]}; shift
mkdir -p "$EVD"
XCTESTRUN=${HV_XCTESTRUN:-$(ls "$HVW"/dd/Build/Products/*.xctestrun | head -1)}
# les clés peuvent venir de l'appelant (lane 7 : il cherche ces clés dans les preuves)
[ -n "${HV_TEST_SSH_KEY:-}" ] && [ -n "${HV_TEST_SSH_WRONG_KEY:-}" ] || new_keys || exit 1
only=()
if [ $# -gt 0 ]; then for t in "$@"; do only+=(-only-testing:"HermedBotsUITests/TunnelTests/$t"); done; else only=(-only-testing:HermedBotsUITests/TunnelTests); fi
say "xcodebuild test-without-building ${only[*]} -> $EVD"
TEST_RUNNER_HV_SSH_HOST=$SSH_HOST TEST_RUNNER_HV_SSH_USER=hvssh \
TEST_RUNNER_HV_TEST_SSH_KEY=$HV_TEST_SSH_KEY TEST_RUNNER_HV_TEST_SSH_WRONG_KEY=$HV_TEST_SSH_WRONG_KEY \
TEST_RUNNER_HV_API_URL=http://127.0.0.1:18642 TEST_RUNNER_HV_SHOTS="$EVD/shots" \
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'platform=macOS' "${only[@]}" \
  -resultBundlePath "$EVD/result.xcresult" > "$EVD/xcodebuild.log" 2>&1
rc=$?
say "xcodebuild rc=$rc"
grep -E "Test Case .*(passed|failed|skipped)|Executed [0-9]+ tests|error:|HV-SHOT|HV-TUNNEL" "$EVD/xcodebuild.log" | sed -E 's/\(.*\) *$//' | head -60
# « Executed 0 tests » avec le code 0 arrive quand le bundle de tests est périmé : ce n'est pas un succès
grep -Eq "Executed [1-9][0-9]* tests?, with 0 failures" "$EVD/xcodebuild.log" || { echo "RUN FAIL: aucun test exécuté ou un test échoue"; [ $rc -eq 0 ] && rc=1; }
exit $rc
