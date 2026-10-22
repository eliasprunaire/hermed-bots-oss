#!/usr/bin/env bash
# Lancer uniquement par vm.sh exec
set -uo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
evidence=${HV_WORK:?}/evidence/hd14-unit-$(date +%Y%m%d-%H%M%S)
mkdir -p "$evidence"
xcodebuild test-without-building -xctestrun "$HV_XCTESTRUN" -destination platform=macOS \
  -only-testing:HermedBotsTests -resultBundlePath "$evidence/result.xcresult" > "$evidence/xcodebuild.log" 2>&1
rc=$?
grep -E 'Test Case .*failed|error:|Executed [0-9]+ tests|TEST EXECUTE' "$evidence/xcodebuild.log"
[ $rc -eq 0 ] || exit "$rc"
bash docs/spike/hd14-instruments/run-ui.sh
