#!/usr/bin/env bash
# Lancer uniquement par vm.sh exec
set -uo pipefail
[ "$HOME" =  ] || { echo 'VM hvtest requise'; exit 2; }
result=0
for mode in lanes perf review; do
  echo "HD14 passe=$mode"
  if [ "$mode" = lanes ]; then
    bash docs/spike/hd14-instruments/run-ui.sh
  else
    bash docs/spike/hd14-instruments/run-ui.sh "$mode"
  fi
  rc=$?
  echo "HD14 passe=$mode rc=$rc"
  [ $rc -eq 0 ] || result=1
done
exit "$result"
