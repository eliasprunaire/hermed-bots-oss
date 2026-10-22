#!/usr/bin/env bash
# Exécuter uniquement par vm.sh exec, jamais sur l’hôte
set -uo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo "VM hvtest requise"; exit 2; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SK=$ROOT/.cursor/skills/verify-hermed-bots/scripts
WORK=${HV_WORK:-$HOME/hermed-bots-work}
XCTESTRUN=${HV_XCTESTRUN:?HV_XCTESTRUN absent : lancer par vm.sh exec}
mode=normal
drop=set_model
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode=${2:?--mode demande une valeur}; shift 2 ;;
    --drop) drop=${2:?--drop demande une valeur}; shift 2 ;;
    *) break ;;
  esac
done
export HV_FAKE_MODE=$mode HV_DROP=$drop
HV_EVIDENCE=$WORK/evidence/hd13-ui-$mode-$(TZ=Europe/Paris date +%Y%m%d-%H%M%S)
export HV_EVIDENCE
mkdir -p "$HV_EVIDENCE"
tests=("$@")
[ ${#tests[@]} -gt 0 ] || tests=(SixActions/testResumeAfterSleep Events)
only=()
for t in "${tests[@]}"; do case "$t" in HermedBots*) only+=(-only-testing:"$t") ;; *) only+=(-only-testing:"HermedBotsUITests/$t") ;; esac; done

"$SK/hv-guard.sh" snapshot "$HV_EVIDENCE/guard-before.txt" || exit $?
HV_PORT=18643 "$SK/hv-hermes-env.sh" up fake || exit $?
python3 "$ROOT/docs/spike/hd13-instruments/cut-proxy.py" > "$HV_EVIDENCE/proxy.log" 2>&1 & PROXY=$!
for _ in {1..25}; do curl -fsS http://127.0.0.1:18642/_hv/ready >/dev/null 2>&1 && break; sleep 0.2; done
STOP=$HV_EVIDENCE/stop-net
bash "$ROOT/docs/spike/hd08-instruments/netsample.sh" "$HV_EVIDENCE/net.txt" "$STOP" & SAMPLER=$!
(
  sample=0
  while [ ! -e "$STOP" ]; do
    pid=$(pgrep -x HermedBots | head -1)
    if [ -n "$pid" ]; then
      bash "$SK/hv-netwatch.sh" "$pid" 1 "$HV_EVIDENCE/netwatch-$sample.txt" 18642 >> "$HV_EVIDENCE/netwatch.log" 2>&1
      watch_rc=$?
      [ "$watch_rc" -eq 0 ] || echo "$watch_rc" > "$HV_EVIDENCE/netwatch-failure"
      sample=$((sample+1))
    else sleep 0.3; fi
  done
) & WATCHER=$!
trap 'kill "$PROXY" 2>/dev/null; touch "$STOP"; wait "$SAMPLER" 2>/dev/null; wait "$WATCHER" 2>/dev/null; HV_PORT=18643 "$SK/hv-hermes-env.sh" down fake >/dev/null 2>&1' EXIT
echo "faux serveur mode=$mode drop=$drop ; xcodebuild test-without-building ${only[*]} -> $HV_EVIDENCE"
TEST_RUNNER_HV13_SINGLE=${HV13_SINGLE:-0} TEST_RUNNER_HV13_PROXY=1 TEST_RUNNER_HV13_BASELINE=${HV13_BASELINE:-0} TEST_RUNNER_HV_TEST_MODE=1 TEST_RUNNER_HV_DROP=$drop TEST_RUNNER_HV_API_URL=http://127.0.0.1:${HV_PORT:-18642} TEST_RUNNER_HV_SHOTS="$HV_EVIDENCE/shots" \
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'platform=macOS' "${only[@]}" \
  -resultBundlePath "$HV_EVIDENCE/result.xcresult" > "$HV_EVIDENCE/xcodebuild.log" 2>&1
rc=$?
echo "xcodebuild rc=$rc"
grep -E "Test Case .*(passed|failed|skipped)|Executed [0-9]+ tests|error:|HV-(PERF13|NOTIFICATION|MODELS|STATE|SHOT)" "$HV_EVIDENCE/xcodebuild.log" | cut -c1-600
shots=()
while read -r name; do shots+=("$name"); done < <(grep -o 'HV-SHOT [^ ]*' "$HV_EVIDENCE/xcodebuild.log" | cut -d' ' -f2 | sort -u)
if [ ${#shots[@]} -gt 0 ]; then
  "$SK/hv-shotdiff.sh" --export "$HV_EVIDENCE/result.xcresult" "$HV_EVIDENCE/shots" "${shots[@]}"
  shot_rc=$?
  [ "$rc" -ne 0 ] || rc=$shot_rc
fi
touch "$STOP"; wait "$SAMPLER" 2>/dev/null; wait "$WATCHER" 2>/dev/null
"$SK/hv-guard.sh" check "$HV_EVIDENCE/guard-before.txt"; guard=$?
# une ligne de netsample.sh : commande, pid, nom lsof (adresse locale, puis `->` et la destination d'une connexion établie), état
destinations=$(awk '{ n = split($3, parts, "->"); if (n == 2) print parts[2] }' "$HV_EVIDENCE/net.txt" | sort -u | tr '\n' ' ')
samples=$(wc -l < "$HV_EVIDENCE/net.txt" | tr -d ' ')
others=$(printf '%s' "$destinations" | tr ' ' '\n' | grep -vx -e '' -e "127.0.0.1:${HV_PORT:-18642}" || true)
if [ "$samples" -gt 0 ] && [ -z "$others" ]; then
  echo "NET OK : $samples relevés lsof de l'app, destinations vues : ${destinations:-aucune}"
elif [ "$samples" -eq 0 ]; then
  echo "NET INCONCLUSIF : aucun socket observé ; le confinement pf reste exigé par vm.sh"
else
  echo "NET FAIL : $samples relevés lsof de l'app, destinations vues : ${destinations:-aucune}"; [ $rc -eq 0 ] && rc=14
fi
if [ -f "$HV_EVIDENCE/netwatch-failure" ]; then
  echo "NETWATCH FAIL code $(cat "$HV_EVIDENCE/netwatch-failure")"; [ $rc -eq 0 ] && rc=14
else echo "NETWATCH OK"; fi
echo "GUARD check code $guard"
[ "$guard" = 0 ] || { [ $rc -eq 0 ] && rc=$guard; }
# « Executed 0 tests » avec le code 0 : le bundle est périmé, ce n'est pas un succès
grep -Eq "Executed [1-9][0-9]* tests?, with 0 failures" "$HV_EVIDENCE/xcodebuild.log" || { echo "RUN FAIL : aucun test exécuté ou un test échoue"; [ $rc -eq 0 ] && rc=1; }
# un test sauté ne prouve rien : la lane échoue quand un test demandé est sauté
if grep -q "Test Case .*skipped" "$HV_EVIDENCE/xcodebuild.log"; then echo "RUN FAIL : un test demandé est sauté"; rc=1; fi
exit $rc
