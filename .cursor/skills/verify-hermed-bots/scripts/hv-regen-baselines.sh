#!/usr/bin/env bash
# hv-regen-baselines.sh — régénère les PNG de baselines/ sur le Mac, via la VM.
# Linux ne produit pas ces captures. Liste : baselines/LACUNES-PNG.md.
# Modèle : aucun. Promotion Dev Lead, avec l'ingénieur, après relecture designer (--bless). Aucune UI sur l'hôte.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=$(cd "$HERE/../baselines" && pwd)
RUNNER=${HV_RUNNER_DIR:-$HERE}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,12p' "$0"
  exit 0
fi

if [ ! -f "$RUNNER/vm.sh" ] || [ ! -r "$RUNNER/vm.sh" ]; then
  echo "Aucun vm.sh exécutable dans le répertoire retenu. Définir HV_RUNNER_DIR." >&2
  exit 2
fi

echo "1. Passe VM (suite ordinaire ui fake) :"
echo "   timeout 3600 zsh ${RUNNER}/vm.sh ui fake"
echo "2. Examiner shots/ et diffs/ dans le dossier annoncé par HV-UI."
echo "3. Promouvoir les captures approuvées :"
echo "   bash $HERE/hv-shotdiff.sh --bless <reference-shots> $BASE"
echo "4. Cocher les noms disparus de $BASE/LACUNES-PNG.md."
echo "Les PNG absents :"
# shellcheck disable=SC2016
sed -n 's/^- LACUNE binaire : `\(.*\)`/\1/p' "$BASE/LACUNES-PNG.md"
echo "Cette commande ne lance pas l'app. Les PNG se produisent dans la VM."
