#!/usr/bin/env bash
set -euo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
ROOT=$(pwd)
WORK=${HV_WORK:-$HOME/hermed-bots-work}
EVD=$WORK/evidence/hd13-comparison-$(date +%Y%m%d-%H%M%S)
BASE=$EVD/trunk
mkdir -p "$BASE/.cursor/skills" "$BASE/docs/spike"
cp -R "$ROOT/.cursor/skills/verify-hermed-bots" "$BASE/.cursor/skills/"
cp -R "$ROOT/Packages" "$ROOT/HermedBotsTests" "$ROOT/HermedBotsUITests" "$BASE/"
cp -R "$ROOT/docs/spike/hd13-instruments" "$ROOT/docs/spike/hd08-instruments" "$BASE/docs/spike/"
tar xzf "$ROOT/docs/spike/hd13-instruments/trunk.tgz" -C "$BASE"
cd "$BASE"
xcodebuild build-for-testing -scheme HermedBots -destination platform=macOS -derivedDataPath "$WORK/dd-hd13-trunk" > "$EVD/build-trunk.log" 2>&1
TRUNK=$(find "$WORK/dd-hd13-trunk/Build/Products" -name '*.xctestrun' -maxdepth 1 | head -1)
HEAD=$HV_XCTESTRUN
for sample in 1 2 3 4 5; do
  echo "HV-COMPARISON sample=$sample side=trunk"
  HV13_SINGLE=1 HV13_BASELINE=1 HV_XCTESTRUN=$TRUNK bash "$BASE/docs/spike/hd13-instruments/run-ui.sh" ResumeBaseline
  echo "HV-COMPARISON sample=$sample side=head"
  cd "$ROOT"
  HV13_SINGLE=1 HV_XCTESTRUN=$HEAD bash docs/spike/hd13-instruments/run-ui.sh ResumeLanes/testResumeBudget
  cd "$BASE"
done
