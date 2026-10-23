#!/usr/bin/env bash
# Lancer uniquement par le script de VM de test
set -uo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
SK=.cursor/skills/verify-hermed-bots/scripts
WORK=${HV_WORK:?}
export HV_EVIDENCE="$WORK/evidence/hd14-ui-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$HV_EVIDENCE"
bash "$SK/hv-guard.sh" snapshot "$HV_EVIDENCE/guard-before.txt" || exit $?
python3 docs/spike/hd14-instruments/fake.py > "$HV_EVIDENCE/fake.log" 2>&1 & SERVER=$!
STOP=$HV_EVIDENCE/stop-net
bash docs/spike/hd08-instruments/netsample.sh "$HV_EVIDENCE/net.txt" "$STOP" & NET=$!
trap 'touch "$STOP"; wait "$NET"; kill "$SERVER"; wait "$SERVER" 2>/dev/null' EXIT
for ((i=0;i<40;i++)); do curl -fsS http://127.0.0.1:18642/_hv/ready > /dev/null 2>&1 && break; sleep 0.25; done
head_run=$HV_XCTESTRUN
mode=${1:-lanes}
if [ "$mode" = baseline ] || [ "$mode" = perf ]; then
  baseline=$WORK/hd14-trunk
  mkdir -p "$baseline"
  tar xf docs/spike/hd14-instruments/trunk-source.tar -C "$baseline"
  cp -R HermedBotsTests HermedBotsUITests "$baseline/"
  xcodebuild build-for-testing -project "$baseline/HermedBots.xcodeproj" -scheme HermedBots -destination platform=macOS -derivedDataPath "$WORK/hd14-trunk-dd" > "$HV_EVIDENCE/baseline-build.log" 2>&1 || { tail -40 "$HV_EVIDENCE/baseline-build.log"; exit 40; }
  trunk_run=$(find "$WORK/hd14-trunk-dd/Build/Products" -name '*.xctestrun' | head -1)
  if [ "$mode" = baseline ]; then
    HV_XCTESTRUN=$trunk_run
    export TEST_RUNNER_HV_HD14_BASELINE=1
    tests=(test01HeldBeforeLaunch testPerfFiveHolds)
  else
    tests=()
    for i in 1 2 3 4 5; do tests+=("trunk-$i:testPerfOneHold" "head-$i:testPerfOneHold"); done
  fi
elif [ "$mode" = review ]; then
  tests=(testRecordedReview)
else
  if [ $# -gt 0 ]; then
    tests=("$@")
  else
    tests=(test01HeldBeforeLaunch test02TakenDuringUse test03NoWriteAfterHold test04OtherProfile test05Release test06ApprovalTaken test08DetectionDropped testPerfFiveHolds)
  fi
fi
rc=0
for run in "${tests[@]}"; do
  test=${run#*:}
  if [ "$mode" = perf ]; then
    case "$run" in
      trunk-*) HV_XCTESTRUN=$trunk_run; export TEST_RUNNER_HV_HD14_BASELINE=1 ;;
      head-*) HV_XCTESTRUN=$head_run; export TEST_RUNNER_HV_HD14_BASELINE=0 ;;
    esac
  fi
  result="$HV_EVIDENCE/$run.xcresult"
  echo "HD14 lane=$run commande=xcodebuild test-without-building -only-testing:HermedBotsUITests/ConcurrencyTests/$test"
  TEST_RUNNER_HV_HD14_LANE=1 TEST_RUNNER_HV_API_URL=http://127.0.0.1:18642 TEST_RUNNER_HV_SHOTS="$HV_EVIDENCE/shots" \
    xcodebuild test-without-building -xctestrun "$HV_XCTESTRUN" -destination platform=macOS \
    -only-testing:"HermedBotsUITests/ConcurrencyTests/$test" -resultBundlePath "$result" > "$HV_EVIDENCE/$run.log" 2>&1
  code=$?
  grep -E 'Test Case .* (passed|failed|skipped)|Executed [0-9]+ test|error:|HV-(SHOT|PERF14)|HD14 BASELINE' "$HV_EVIDENCE/$run.log"
  echo "HD14 lane=$run rc=$code"
  [ $code -eq 0 ] || rc=1
  grep -q "Test Case .* passed" "$HV_EVIDENCE/$run.log" || rc=1
  shots=()
  while read -r shot; do shots+=("$shot"); done < <(sed -n 's/.*HV-SHOT \([^ ]*\).*/\1/p' "$HV_EVIDENCE/$run.log" | sort -u)
  if [ ${#shots[@]} -gt 0 ]; then
    bash "$SK/hv-shotdiff.sh" --export "$result" "$HV_EVIDENCE/shots" "${shots[@]}" || rc=1
  fi
done
touch "$STOP"; wait "$NET"
bash "$SK/hv-guard.sh" check "$HV_EVIDENCE/guard-before.txt" > "$HV_EVIDENCE/guard-after.txt"; guard=$?
echo "HD14 lane=9 GUARD rc=$guard"
[ $guard -eq 0 ] || rc=$guard
destinations=$(awk '{ n = split($3, parts, "->"); if (n == 2) print parts[2] }' "$HV_EVIDENCE/net.txt" | sort -u)
if [ -s "$HV_EVIDENCE/net.txt" ] && ! echo "$destinations" | grep -vx -e '' -e '127.0.0.1:18642'; then
  echo "HD14 lane=10 NET OK destinations=$destinations"
else
  echo "HD14 lane=10 NET sans preuve ou destination interdite"; rc=1
fi
exit "$rc"
