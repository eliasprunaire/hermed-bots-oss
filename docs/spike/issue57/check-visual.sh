#!/usr/bin/env bash
set -euo pipefail
[ "$HOME" =  ] || { echo 'VM hvtest requise'; exit 2; }
SK=.cursor/skills/verify-hermed-bots/scripts
evd=${HV_WORK:?}/evidence/issue57-visual-$(TZ=Europe/Paris date +%Y%m%d-%H%M%S)
mkdir -p "$evd/base" "$evd/shots" "$evd/diffs"
magick -size 100x100 xc:white "$evd/base/screen.png"
cp "$evd/base/screen.png" "$evd/shots/screen.png"
bash "$SK/hv-shotdiff.sh" "$evd/shots" "$evd/base" "$evd/diffs" 0.02
magick "$evd/base/screen.png" -fill black -draw 'rectangle 0,0 99,1' "$evd/shots/screen.png"
bash "$SK/hv-shotdiff.sh" "$evd/shots" "$evd/base" "$evd/diffs" 0.02
magick "$evd/base/screen.png" -fill black -draw 'rectangle 0,0 99,2' "$evd/shots/screen.png"
rc=0
bash "$SK/hv-shotdiff.sh" "$evd/shots" "$evd/base" "$evd/diffs" 0.02 || rc=$?
[ "$rc" = 11 ] && [ -s "$evd/diffs/screen.png" ]
echo "ISSUE57 VISUAL identique=0 seuil-2pct=0 écart-3pct=$rc diff=$evd/diffs/screen.png"
