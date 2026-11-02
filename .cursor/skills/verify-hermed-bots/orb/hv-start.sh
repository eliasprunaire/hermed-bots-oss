#!/bin/sh
# Container main program (CMD) of hv-hermes:spike. Runs as the `hermes` user, HERMES_HOME=/opt/data
# Seeds the test profiles, starts the fake model provider, then runs the gateway with the API server
# The key comes from HV_TEST_API_KEY (docker run --env HV_TEST_API_KEY); it is never an image layer
# and it lands only in files of the container's own volume, removed by `docker rm -v`
set -eu

[ -n "${HV_TEST_API_KEY:-}" ] || { echo "hv-start: HV_TEST_API_KEY absent" >&2; exit 32; }
export HERMES_HOME="${HERMES_HOME:-/opt/data}" HOME="${HOME:-/opt/data}"
export API_SERVER_KEY="$HV_TEST_API_KEY"

# The nine active profiles of the PRD ("default" is HERMES_HOME itself), plus the test profiles
PRD_PROFILES="cyber gaming ia perso recherches sport tiny wikilibriste"
TEST_PROFILES="hv-bot-a hv-bot-b hv-old"

python3 /opt/hv/fake-llm.py 9999 2>>"$HERMES_HOME/logs/hv-fake-llm.log" &

for p in $PRD_PROFILES $TEST_PROFILES; do
    [ -d "$HERMES_HOME/profiles/$p" ] || hermes profile create "$p" --no-alias --no-skills >/dev/null
done
# hv-old is the inactive profile: gateway.parked is the marker `hermes -p X gateway stop` writes
touch "$HERMES_HOME/profiles/hv-old/gateway.parked"

cd /opt/hermes
/opt/hermes/.venv/bin/python - <<'PY'
import os
import pathlib

import hermes_yaml

home = pathlib.Path(os.environ["HERMES_HOME"])
key = os.environ["HV_TEST_API_KEY"]
model = {"default": "hv-fake-1", "provider": "custom", "base_url": "http://127.0.0.1:9999/v1", "api_key": "none"}
for d in [home] + sorted((home / "profiles").iterdir()):
    if not (d / "config.yaml").is_file():
        continue
    cfg = hermes_yaml.safe_load((d / "config.yaml").read_text()) or {}
    cfg["model"] = model
    (d / "config.yaml").write_text(hermes_yaml.safe_dump(cfg))
    env = d / ".env"
    lines = [l for l in (env.read_text().splitlines() if env.exists() else []) if not l.startswith("API_SERVER_KEY=")]
    env.write_text("\n".join(lines + [f"API_SERVER_KEY={key}"]) + "\n")
    env.chmod(0o600)
PY

echo "hv-start: seeded, starting gateway" >&2
exec hermes gateway run
