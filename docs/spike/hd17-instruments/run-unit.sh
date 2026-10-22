#!/usr/bin/env bash
set -euo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
EVD="$HOME/hermed-bots-work/evidence/hd17-unit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$EVD"
xcodebuild test-without-building -xctestrun "$HV_XCTESTRUN" -destination platform=macOS -only-testing:HermedBotsTests -resultBundlePath "$EVD/result.xcresult" > "$EVD/xcodebuild.log" 2>&1
rg 'Executed .* tests|Test Suite .*passed' "$EVD/xcodebuild.log" || grep -E 'Executed .* tests|Test Suite .*passed' "$EVD/xcodebuild.log"
