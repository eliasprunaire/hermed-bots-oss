#!/usr/bin/env bash
# Lancer uniquement par le script de VM de test
set -uo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
SK=.cursor/skills/verify-hermed-bots/scripts
WORK=${HV_WORK:?}
HV_EVIDENCE="$WORK/evidence/hd15-ui-$(date +%Y%m%d-%H%M%S)"
export HV_EVIDENCE
mkdir -p "$HV_EVIDENCE"
bash "$SK/hv-guard.sh" snapshot "$HV_EVIDENCE/guard-before.txt" || exit $?
python3 docs/spike/hd15-instruments/fake.py > "$HV_EVIDENCE/fake.log" 2>&1 & SERVER=$!
STOP=$HV_EVIDENCE/stop-net
bash docs/spike/hd08-instruments/netsample.sh "$HV_EVIDENCE/net.txt" "$STOP" & NET=$!
trap 'touch "$STOP"; wait "$NET"; kill "$SERVER"; wait "$SERVER" 2>/dev/null' EXIT
for ((i=0;i<40;i++)); do curl -fsS http://127.0.0.1:18642/_hv/ready > /dev/null 2>&1 && break; sleep 0.25; done
mode=${1:-lanes}
if [ "$mode" = baseline ] || [ "$mode" = perf ]; then
  baseline=$WORK/hd15-trunk
  mkdir -p "$baseline"
  [ -f docs/spike/hd15-instruments/trunk-source.tar ] || { echo 'Préparer sur le Mac : git archive origin/main -o docs/spike/hd15-instruments/trunk-source.tar'; exit 2; }
  tar xf docs/spike/hd15-instruments/trunk-source.tar -C "$baseline"
  cp HermedBotsUITests/KillSwitchTests.swift "$baseline/HermedBotsUITests/"
  xcodebuild build-for-testing -project "$baseline/HermedBots.xcodeproj" -scheme HermedBots -destination platform=macOS -derivedDataPath "$WORK/hd15-trunk-dd" > "$HV_EVIDENCE/baseline-build.log" 2>&1 || { tail -40 "$HV_EVIDENCE/baseline-build.log"; exit 40; }
  trunk_run=$(find "$WORK/hd15-trunk-dd/Build/Products" -name '*.xctestrun' | head -1)
  if [ "$mode" = baseline ]; then
    HV_XCTESTRUN=$trunk_run
    export TEST_RUNNER_HV_HD15_BASELINE=1
    tests=(test01ThreeRunningTurns)
  else
    tests=(testPerfFiveStops)
  fi
else
  if [ $# -gt 0 ]; then
    tests=("$@")
  else
    tests=(test01ThreeRunningTurns test03Idle test04NoTunnel test05DroppedCancel test06DoubleClick test07KeptSessions test08WaitingApproval testPerfFiveStops Errors:testLoopPause Errors:testRefusedKey)
  fi
fi

rc=0
for run in "${tests[@]}"; do
  test=${run#*:}
  class=KillSwitchTests
  if [[ "$run" == *:* ]]; then class=${run%%:*}; fi
  result="$HV_EVIDENCE/$run.xcresult"
  echo "HD15 lane=$run commande=xcodebuild test-without-building -only-testing:HermedBotsUITests/$class/$test"
  TEST_RUNNER_HV_HD15_LANE=1 TEST_RUNNER_HV_API_URL=http://127.0.0.1:18642 TEST_RUNNER_HV_SHOTS="$HV_EVIDENCE/shots" \
    xcodebuild test-without-building -xctestrun "$HV_XCTESTRUN" -destination platform=macOS \
    -only-testing:"HermedBotsUITests/$class/$test" -resultBundlePath "$result" > "$HV_EVIDENCE/$run.log" 2>&1
  code=$?
  grep -E 'Test Case .* (passed|failed|skipped)|Executed [0-9]+ test|error:|HV-(SHOT|PERF15)|HD15 BASELINE' "$HV_EVIDENCE/$run.log"
  echo "HD15 lane=$run rc=$code"
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
echo "HD15 lane=10 GUARD rc=$guard"
[ $guard -eq 0 ] || rc=$guard
destinations=$(awk '{ n = split($3, parts, "->"); if (n == 2) print parts[2] }' "$HV_EVIDENCE/net.txt" | sort -u)
if [ "$mode" = baseline ]; then
  echo "HD15 baseline réseau non mesuré, la lane 10 porte sur head"
elif [ -s "$HV_EVIDENCE/net.txt" ] && ! echo "$destinations" | grep -vx -e '' -e '127.0.0.1:18642'; then
  echo "HD15 lane=10 NET OK destinations=$destinations"
else
  echo "HD15 lane=10 NET sans preuve ou destination interdite"; rc=1
fi
mkdir -p "$HV_EVIDENCE/shots"
{
  echo 'HD15 lane 10. Transcription de la garde et du réseau, rendue dans la VM.'
  cat "$HV_EVIDENCE/guard-before.txt" "$HV_EVIDENCE/guard-after.txt"
  echo "guard_rc=$guard"
  echo "Destinations observées : $destinations"
  sort -u "$HV_EVIDENCE/net.txt"
} > "$HV_EVIDENCE/net-guard-render.txt"
magick -background '#1e1e1e' -fill '#e6e6e6' -font /System/Library/Fonts/Menlo.ttc -pointsize 14 \
  "label:@$HV_EVIDENCE/net-guard-render.txt" -bordercolor '#1e1e1e' -border 16 "$HV_EVIDENCE/shots/hd15-net-guard.png" || rc=1
if [ "$mode" = lanes ]; then
  bash docs/spike/hd15-instruments/orb-ui.sh
  orb_rc=$?
  echo "HD15 lanes=2,9 UI OrbStack/manual rc=$orb_rc (6 = préconditions manquantes)"
  [ "$orb_rc" = 6 ] || rc=1
fi
exit "$rc"
