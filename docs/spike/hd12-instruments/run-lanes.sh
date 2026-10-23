#!/usr/bin/env bash
# Lancer uniquement avec zsh <vm-test-script> exec bash docs/spike/hd12-instruments/run-lanes.sh
set -uo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo "VM hvtest requise"; exit 2; }
lane_script=docs/spike/hd12-instruments/run-ui.sh
result=0
run_lane() {
  lane=$1
  shift
  echo "HD12 lane=$lane commande=bash $lane_script $*"
  bash "$lane_script" "$@"
  rc=$?
  echo "HD12 lane=$lane rc=$rc"
  [ "$rc" -eq 0 ] || result=1
}
run_lane 1 Compat/testRouteRemoved
run_lane 2 Compat/testApproveRemoved
run_lane 3 Errors/testApiUnreachable
run_lane 4 Errors/testApiSlow
run_lane 5 Errors/testRefusedKey
run_lane 6 Errors/testLoopPause
run_lane 7 Compat/testNoTokens
HV_FAKE_VERSION=previous run_lane 8 Compat/testRecentVersion
run_lane 9 Errors/testRetry
run_lane 10 Compat/testUnknownVersion
run_lane unit Compat/testFieldsAddedRemoved HermedBotsTests/ConversationModelTests
run_lane regression SixActions/testConversation SixActions/testExpandingABotListsItsPastThreadsWithOneRequest SixActions/testReopeningAThreadShowsItsTranscriptAndSendsNothing
run_lane perf BannerPerfProbe
review=${HV_WORK:?HV_WORK absent}/evidence/hd12-review-shots-$(date +%Y%m%d-%H%M%S)
mkdir -p "$review" "$HV_WORK/review"
for scene in degraded down loop-pause; do
  shot=$(ls -t "$HV_WORK"/evidence/hd12-ui-*/shots/hd12-"$scene".png 2>/dev/null | head -1)
  if [ -n "$shot" ]; then
    cp "$shot" "$review/hd12-review-$scene.png"
    cp "$shot" "$HV_WORK/review/hd12-review-$scene.png"
  else
    echo "HD12 review hd12-review-$scene.png : capture absente"
  fi
done
exit "$result"
