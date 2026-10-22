#!/usr/bin/env bash
set -uo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
bash docs/spike/hd13-instruments/run-comparison.sh
rc=$?
case "$rc" in 14|20|21|22) exit "$rc" ;; esac
for test in \
  SixActions/testResumeAfterSleep \
  Events/testUnknownEventIgnored \
  ResumeLanes/testCompletedDuringCut \
  ResumeLanes/testZeroSecondCut \
  ResumeLanes/testTenMinuteCut \
  ResumeLanes/testApprovalAcrossCut \
  ResumeLanes/testCutBeforeAcknowledgement \
  ResumeLanes/testRelaunchMidTurn \
  ResumeLanes/testOnlyIDsPersist \
  ResumeLanes/testNetworkGuardCapture \
  ResumeLanes/testApprovalWithDetectorCut \
  ResumeLanes/testLoopGuardCountsAcrossReplay
do
  echo "HV-LANE test=$test endpoint=fake"
  bash docs/spike/hd13-instruments/run-ui.sh "$test"
  lane=$?
  echo "HV-LANE test=$test rc=$lane"
  case "$lane" in 14|20|21|22) exit "$lane" ;; esac
  [ "$lane" -eq 0 ] || rc=$lane
done
exit "$rc"
