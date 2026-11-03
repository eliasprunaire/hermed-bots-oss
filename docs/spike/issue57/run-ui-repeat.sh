#!/usr/bin/env bash
set -euo pipefail
[ "$(id -un)" = hvtest ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
bash "${HV_SKILL_SCRIPTS:-.local-skills/verify-hermed-bots/scripts}/hv-selftest.sh"
bash docs/spike/issue57/check-visual.sh
tests=(
  SixActions/testADroppedApproveRouteShowsTheRequestWithTheDisabledMessageAndTheKillSwitch
  SixActions/testAnEmptyProfileListShowsAClearMessage
  SixActions/testAProfileAddedWhileTheAppRunsShowsOnlyAfterTheValidation
  SixActions/testASlowServerShowsAWaitStateAndTheWindowStaysResponsive
  SixActions/testDroppingListSessionsDisablesTheThreadsAloneWithAMessage
  SixActions/testDroppingSetModelDisablesThePickerAloneWithItsMessageAndSendingStillWorks
  SixActions/testLongEmojiAndRightToLeftNamesAreTruncatedAndReadable
  SixActions/testWithoutNamesTheRowsShowTheProfileIdAndTheThreadsShowTheirId
  TunnelTests/testAnExampleHostInTheEnvironmentNeverStartsSsh
)
for run in 1 2 3; do
  echo "ISSUE57 répétition=$run tests=${#tests[@]}"
  bash docs/spike/hd12-instruments/run-ui.sh "${tests[@]}"
done
