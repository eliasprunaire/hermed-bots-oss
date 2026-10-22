#!/usr/bin/env bash
# Rendu de journaux, sans capture de l'écran hôte
set -euo pipefail
input=${1:?journal requis}; title=${2:?titre requis}; output=${3:?sortie requise}
render=${output%.png}.render.txt
{
  echo "HD-14 $(date '+%F %T%z') (transcription de terminal rendue en image)"
  echo "$title"
  echo
  fold -s -w 140 "$input"
} > "$render"
magick -background '#1e1e1e' -fill '#e6e6e6' -font /System/Library/Fonts/Menlo.ttc -pointsize 15 "label:@$render" -bordercolor '#1e1e1e' -border 16 "$output"
