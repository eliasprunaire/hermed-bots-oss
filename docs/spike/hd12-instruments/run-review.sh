#!/usr/bin/env bash
# Lancer uniquement par le script de VM de test dans la session Aqua de la VM
set -euo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo "VM hvtest requise"; exit 2; }
bash docs/spike/hd12-instruments/run-ui.sh HD12Video
