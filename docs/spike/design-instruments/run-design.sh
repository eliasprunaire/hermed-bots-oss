#!/usr/bin/env bash
# Exécuter uniquement par vm.sh exec, jamais sur l’hôte : captures de rendu en apparence sombre et à la taille minimale de la fenêtre
set -euo pipefail
[ "$(id -un)" = hvtest ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo "VM hvtest requise"; exit 2; }
# une clé par profil servi, comme hv-run.sh ui fake : sans elle, le faux serveur refuse et l'app affiche « Clé API absente »
HV_TEST_API_KEYS=$(python3 - Packages/HermesAdapter/Tests/HermesAdapterTests/Fixtures/hermes-current/contract.json <<'PYKEYS'
import json, secrets, sys
print(json.dumps({profile: secrets.token_urlsafe(32) for profile in json.load(open(sys.argv[1]))["profiles"]["served"]}))
PYKEYS
)
export HV_TEST_API_KEYS TEST_RUNNER_HV_TEST_API_KEYS=$HV_TEST_API_KEYS TEST_RUNNER_HV_DESIGN_LANE=1
bash docs/spike/hd12-instruments/run-ui.sh DesignShots "$@"
