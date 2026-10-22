#!/usr/bin/env bash
set -euo pipefail
[ "$HOME" =  ] && [ -n "${HV_XCTESTRUN:-}" ] || { echo 'VM hvtest requise'; exit 2; }
proof="$HOME/hermed-bots-work/evidence/issue58-selftest-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$proof"
bash .cursor/skills/verify-hermed-bots/scripts/hv-selftest.sh > "$proof/selftest.log" 2>&1 || { tail -20 "$proof/selftest.log"; exit 1; }
tail -3 "$proof/selftest.log"
export HV_TEST_API_KEYS
HV_TEST_API_KEYS=$(python3 - <<'PY'
import json, secrets
print(json.dumps({p: secrets.token_urlsafe(32) for p in ['hv-bot-a', 'hv-bot-b']}))
PY
)
export TEST_RUNNER_HV_TEST_API_KEYS="$HV_TEST_API_KEYS"
bash docs/spike/hd12-instruments/run-ui.sh VersionProfiles
