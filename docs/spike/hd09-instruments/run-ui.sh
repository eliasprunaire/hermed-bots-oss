#!/usr/bin/env bash
# run-ui.sh [Classe/test ...] : une passe UI ciblée de HD-09 contre le faux serveur, sans le reste de la suite
# Dans la VM : zsh <vm-test-script> exec bash docs/spike/hd09-instruments/run-ui.sh SixActions/testConversation ConversationPerfProbe
# le script de VM de test exporte HV_XCTESTRUN après build-for-testing et rapatrie le dossier de preuves créé sous $HV_WORK/evidence
# Sans argument : toutes les classes de HD-09
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SK=$ROOT/.cursor/skills/verify-hermed-bots/scripts
WORK=${HV_WORK:-$HOME/hermed-bots-work}
XCTESTRUN=${HV_XCTESTRUN:?HV_XCTESTRUN absent : lancer par le script de VM de test}
HV_EVIDENCE=$WORK/evidence/hd09-ui-$(TZ=Europe/Paris date +%Y%m%d-%H%M%S)
export HV_EVIDENCE
mkdir -p "$HV_EVIDENCE"
tests=("$@")
[ ${#tests[@]} -gt 0 ] || tests=(SixActions ConversationPerfProbe)
only=()
for t in "${tests[@]}"; do only+=(-only-testing:"HermedBotsUITests/$t"); done

"$SK/hv-hermes-env.sh" up fake || exit $?
trap '"$SK/hv-hermes-env.sh" down fake >/dev/null 2>&1' EXIT
echo "xcodebuild test-without-building ${only[*]} -> $HV_EVIDENCE"
TEST_RUNNER_HV_TEST_MODE=1 TEST_RUNNER_HV_API_URL=http://127.0.0.1:${HV_PORT:-18642} TEST_RUNNER_HV_SHOTS="$HV_EVIDENCE/shots" \
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'platform=macOS' "${only[@]}" \
  -resultBundlePath "$HV_EVIDENCE/result.xcresult" > "$HV_EVIDENCE/xcodebuild.log" 2>&1
rc=$?
echo "xcodebuild rc=$rc"
grep -E "Test Case .*(passed|failed|skipped)|Executed [0-9]+ tests|error:|HV-(PERF09|STATE|CONVERSATION|NEW|LONG|ORB-SEND|DEBUG|SHOT)" "$HV_EVIDENCE/xcodebuild.log" | cut -c1-400
shots=()
while read -r name; do shots+=("$name"); done < <(grep -o 'HV-SHOT [^ ]*' "$HV_EVIDENCE/xcodebuild.log" | cut -d' ' -f2 | sort -u)
"$SK/hv-shotdiff.sh" --export "$HV_EVIDENCE/result.xcresult" "$HV_EVIDENCE/shots" ${shots[@]+"${shots[@]}"}
# « Executed 0 tests » avec le code 0 : le bundle est périmé, ce n'est pas un succès
grep -Eq "Executed [1-9][0-9]* tests?, with 0 failures" "$HV_EVIDENCE/xcodebuild.log" || { echo "RUN FAIL : aucun test exécuté ou un test échoue"; [ $rc -eq 0 ] && rc=1; }
exit $rc
