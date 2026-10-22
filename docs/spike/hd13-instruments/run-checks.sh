#!/usr/bin/env bash
set -uo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
bash docs/spike/hd13-instruments/run-ui.sh HermedBotsTests
unit=$?
bash docs/spike/hd12-instruments/run-ui.sh SixActions/testResumeAfterSleep SixActions/testSelectingTheSameOptionTwiceFastSendsOneSetModel
ui=$?
echo "HV-CHECKS unit=$unit ui=$ui"
[ "$unit" -eq 0 ] && [ "$ui" -eq 0 ]
