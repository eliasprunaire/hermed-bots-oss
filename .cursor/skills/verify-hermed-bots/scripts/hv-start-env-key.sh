#!/usr/bin/env bash
# hv-start-env-key.sh — .env au premier volume, clé distincte conservée, chmod 600.
# Usage : hv-start-env-key.sh [HERMES_HOME]
# Sans argument : $HERMES_HOME, sinon le premier volume du conteneur
# ${HV_CONTAINER:-hv-hermes-test} (destination du montage n°0).
# N'écrit API_SERVER_KEY que si la ligne manque. Ne jamais afficher une clé.
# Modèle : aucun.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,8p' "$0"
  exit 0
fi

_seed_dir() {
  python3 - "$1" <<'PY'
import pathlib, secrets, sys
root = pathlib.Path(sys.argv[1])
if not root.is_dir():
    sys.stderr.write("hv-start-env-key: dossier Hermes introuvable\n")
    sys.exit(2)
homes = [root]
profiles = root / "profiles"
if profiles.is_dir():
    homes.extend(sorted(p for p in profiles.iterdir() if p.is_dir()))
written = 0
kept = 0
for folder in homes:
    env_path = folder / ".env"
    lines = env_path.read_text(encoding="utf-8").splitlines() if env_path.exists() else []
    existing = [line for line in lines if line.startswith("API_SERVER_KEY=") and line.split("=", 1)[1].strip()]
    if existing:
        kept += 1
        env_path.chmod(0o600)
        continue
    key = secrets.token_urlsafe(32)
    lines = [line for line in lines if not line.startswith("API_SERVER_KEY=")]
    lines.append("API_SERVER_KEY=" + key)
    env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    env_path.chmod(0o600)
    written += 1
sys.stdout.write("hv-start-env-key: kept=%d written=%d (valeurs omises)\n" % (kept, written))
PY
}

if [ -n "${1:-}" ]; then
  _seed_dir "$1"
  exit 0
fi
if [ -n "${HERMES_HOME:-}" ] && [ -d "$HERMES_HOME" ]; then
  _seed_dir "$HERMES_HOME"
  exit 0
fi

CT=${HV_CONTAINER:-hv-hermes-test}
if ! command -v docker >/dev/null 2>&1; then
  echo "usage: $0 <HERMES_HOME>" >&2
  exit 2
fi
if [ -z "$(docker ps -q --filter "name=^${CT}$")" ]; then
  echo "usage: $0 <HERMES_HOME>  (conteneur $CT absent)" >&2
  exit 2
fi
DEST=$(docker inspect -f '{{if gt (len .Mounts) 0}}{{(index .Mounts 0).Destination}}{{end}}' "$CT")
[ -n "$DEST" ] || { echo "hv-start-env-key: premier volume absent" >&2; exit 2; }
# seed in-container; python prints counts only
docker exec -i -u hermes -e HERMES_HOME="$DEST" "$CT" python3 - "$DEST" <<'PY'
import pathlib, secrets, sys
root = pathlib.Path(sys.argv[1])
homes = [root]
profiles = root / "profiles"
if profiles.is_dir():
    homes.extend(sorted(p for p in profiles.iterdir() if p.is_dir()))
written = 0
kept = 0
for folder in homes:
    env_path = folder / ".env"
    lines = env_path.read_text(encoding="utf-8").splitlines() if env_path.exists() else []
    existing = [line for line in lines if line.startswith("API_SERVER_KEY=") and line.split("=", 1)[1].strip()]
    if existing:
        kept += 1
        env_path.chmod(0o600)
        continue
    key = secrets.token_urlsafe(32)
    lines = [line for line in lines if not line.startswith("API_SERVER_KEY=")]
    lines.append("API_SERVER_KEY=" + key)
    env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    env_path.chmod(0o600)
    written += 1
sys.stdout.write("hv-start-env-key: kept=%d written=%d (valeurs omises)\n" % (kept, written))
PY
