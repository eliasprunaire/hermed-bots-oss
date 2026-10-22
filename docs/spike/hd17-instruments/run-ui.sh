#!/usr/bin/env bash
set -euo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
export HV_TEST_API_KEYS
HV_TEST_API_KEYS=$(python3 - <<'PY'
import json, secrets
print(json.dumps({p: secrets.token_urlsafe(32) for p in ['default','cyber','gaming','ia','perso','recherches','sport','tiny','wikilibriste','hv-bot-a','hv-bot-b']}))
PY
)
export TEST_RUNNER_HV_TEST_API_KEYS="$HV_TEST_API_KEYS"
bash docs/spike/hd12-instruments/run-ui.sh ProfileKeys
python3 - <<'PY'
import json, os
from pathlib import Path
keys = json.loads(os.environ['HV_TEST_API_KEYS'])
root = Path.home() / 'hermed-bots-work/evidence'
for path in root.rglob('*'):
    if path.is_file():
        data = path.read_bytes()
        assert not any(key.encode() in data for key in keys.values()), 'Clé de test présente dans les preuves'
print('HD17 SECRETSCAN: aucune clé de test dans les preuves de la VM')
PY
