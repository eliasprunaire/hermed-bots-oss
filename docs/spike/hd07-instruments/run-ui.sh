#!/usr/bin/env bash
# run-ui.sh <dossier-de-preuves> [test ...] : lance les tests UI du tunnel contre hv-hermes-test
# Le conteneur doit déjà tourner (hv-ssh-endpoint.sh up). L'alias et la clé éphémères viennent de new_alias (lib.sh) et ne touchent pas le dossier de preuves
# HV_XCTESTRUN : fichier .xctestrun de build-for-testing ; HV_FILTER : -only-testing, par défaut tous les TunnelTests
# hv-run.sh ne transmet pas HV_SSH_HOST au runner de tests : ce script fait cet appel à sa place
# HV_SSH_ALIAS remplace l'alias par défaut ($SSH_ALIAS) ; HV_SSH_REFUSED=1 active le test de l'identité refusée, avec l'alias $SSH_ALIAS_REFUSED
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EVD=${1:?usage: run-ui.sh <dossier-de-preuves> [test ...]}; shift
mkdir -p "$EVD"
XCTESTRUN=${HV_XCTESTRUN:-$(ls "$HVW"/dd/Build/Products/*.xctestrun | head -1)}
# l'alias peut venir de l'appelant (lane 7 : il cherche la clé de cet alias dans les preuves) ; sinon il est créé ici et retiré à la sortie
new_alias || exit 1
trap drop_alias EXIT
only=()
if [ $# -gt 0 ]; then for t in "$@"; do only+=(-only-testing:"HermedBotsUITests/TunnelTests/$t"); done; else only=(-only-testing:HermedBotsUITests/TunnelTests); fi
say "xcodebuild test-without-building ${only[*]} -> $EVD"
TEST_RUNNER_HV_SSH_HOST=${HV_SSH_ALIAS:-$SSH_ALIAS} TEST_RUNNER_HV_SSH_REFUSED=${HV_SSH_REFUSED:-} \
TEST_RUNNER_HV_API_URL=http://127.0.0.1:18642 TEST_RUNNER_HV_SHOTS="$EVD/shots" \
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'platform=macOS' "${only[@]}" \
  -resultBundlePath "$EVD/result.xcresult" > "$EVD/xcodebuild.log" 2>&1
rc=$?
say "xcodebuild rc=$rc"
grep -E "Test Case .*(passed|failed|skipped)|Executed [0-9]+ tests|error:|HV-SHOT|HV-TUNNEL" "$EVD/xcodebuild.log" | sed -E 's/\(.*\) *$//' | head -60
# « Executed 0 tests » avec le code 0 arrive quand le bundle de tests est périmé : ce n'est pas un succès
grep -Eq "Executed [1-9][0-9]* tests?, with 0 failures" "$EVD/xcodebuild.log" || { echo "RUN FAIL: aucun test exécuté ou un test échoue"; [ $rc -eq 0 ] && rc=1; }
exit $rc
