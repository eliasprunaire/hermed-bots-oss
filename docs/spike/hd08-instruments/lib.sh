# shellcheck shell=bash
# source ce fichier : variables et fonctions communes des lanes HD-08
# Les lanes tournent sur le Mac contre le faux serveur ou hv-hermes-test seulement, jamais contre autre chose
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
HVW=${HV_WORK:-$HOME/hermed-bots-work}
SK=$REPO/.cursor/skills/verify-hermed-bots/scripts
FIXDIR=$HVW/hd08-fixtures
PORT=18642
URL=http://127.0.0.1:$PORT
CT=hv-hermes-test
SSH_HOST=host.example
export SSH_HOST
export PATH="$PATH:/usr/sbin"

say() { printf '[%s Paris] %s\n' "$(TZ=Europe/Paris date +%H:%M:%S)" "$*"; }

discover_forbidden_probe() {
  if [ -n "${HV_FORBIDDEN_HOST:-}" ]; then
    printf '%s' "$HV_FORBIDDEN_HOST"
    return 0
  fi
  python3 - "$SK/hv-guard.sh" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    text = path.read_text(encoding="utf-8")
except OSError:
    sys.exit(1)
skip = {"example-host", "example-host.invalid", "host.example", "forbidden", "forbidden.invalid"}
for match in re.finditer(r"\*([A-Za-z0-9._-]+)\*\)", text):
    pat = match.group(1)
    after = text[match.end() : match.end() + 160]
    if not re.search(r"\b22\b", after):
        continue
    if pat.lower() in skip:
        continue
    sys.stdout.write(pat if "." in pat else f"{pat}.invalid")
    sys.exit(0)
sys.exit(1)
PY
}

require_forbidden_target() {
  probe=$(discover_forbidden_probe) || {
    echo "RESULT FAIL : no forbidden probe from hv-guard.sh, aucune lane lancée"
    exit 1
  }
  g=0
  "$SK/hv-guard.sh" target "$probe" || g=$?
  echo "hv-guard.sh target forbidden-probe : code $g (22 attendu)"
  [ "$g" = 22 ] || { echo "RESULT FAIL : hv-guard.sh target forbidden-probe code $g, 22 attendu, aucune lane lancée"; exit 1; }
}
cmd() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf 'rc=%s\n' "$rc"; return 0; }

xctestrun() { ls "$HVW/${1:-dd}"/Build/Products/*.xctestrun | head -1; }

# fake_up <variante|base> [mode] [route] : un faux serveur frais sur 127.0.0.1:18642 ; le journal repart de zéro
# la variante vient de mk-fixtures.py ; le serveur est lancé par PID, jamais tué par nom
fake_up() {
  local variant=${1:-base} mode=${2:-normal} drop=${3:-set_model} fixtures="$SK/../fixtures"
  [ "$variant" = base ] || fixtures="$FIXDIR/$variant"
  fake_down
  HV_DROP=$drop python3 "$SK/hv-fake-hermes.py" --port "$PORT" --version current --mode "$mode" --fixtures "$fixtures" > "${EVD:-/tmp}/fake-$variant.log" 2>&1 &
  FAKE_PID=$!
  for _ in $(seq 1 40); do curl -fsS -m 1 "$URL/_hv/ready" >/dev/null 2>&1 && { say "faux serveur $variant/$mode prêt (pid $FAKE_PID, $URL)"; return 0; }; sleep 0.25; done
  say "FAUX SERVEUR PAS PRÊT"; return 1
}
fake_down() { [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null && wait "$FAKE_PID" 2>/dev/null; FAKE_PID=; return 0; }

# run_ui <dossier> <xctestrun> <classe/test...> : XCUITest contre $URL ; les variables TEST_RUNNER_* de l'appelant passent
# rend 0 seulement si « Executed N tests, with 0 failures » avec N >= 1
run_ui() {
  local evd=$1 xr=$2; shift 2
  local only=() t
  for t in "$@"; do only+=(-only-testing:"HermedBotsUITests/$t"); done
  mkdir -p "$evd"
  # xcodebuild refuse un paquet de résultats qui existe déjà : celui d'une passe précédente part à la corbeille
  [ -e "$evd/result.xcresult" ] && trash "$evd/result.xcresult"
  say "xcodebuild test-without-building ${only[*]} -> $evd"
  TEST_RUNNER_HV_API_URL=${TEST_RUNNER_HV_API_URL-$URL} TEST_RUNNER_HV_SHOTS="$evd/shots" \
    xcodebuild test-without-building -xctestrun "$xr" -destination 'platform=macOS' "${only[@]}" \
    -resultBundlePath "$evd/result.xcresult" > "$evd/xcodebuild.log" 2>&1
  local rc=$?
  say "xcodebuild rc=$rc"
  grep -E "Test Case .*(passed|failed|skipped)|Executed [0-9]+ tests|error:|HV-[A-Z]+[0-9]* " "$evd/xcodebuild.log" | sed -E 's/\(.*\) *$//' | cut -c1-600 | awk '!seen[$0]++' | head -60
  grep -Eq "Executed [1-9][0-9]* tests?, with 0 failures" "$evd/xcodebuild.log" || { echo "RUN FAIL : aucun test exécuté ou un test échoue"; [ $rc -eq 0 ] && rc=1; }
  # un test sauté ne prouve rien : la lane échoue quand un test demandé est sauté
  if grep -q "Test Case .*skipped" "$evd/xcodebuild.log"; then echo "RUN FAIL : un test demandé est sauté"; rc=1; fi
  return $rc
}

# export_shots <dossier> <nom...> : sort les captures HVShot du xcresult vers <dossier>/shots/<nom>.png
export_shots() {
  local evd=$1; shift
  "$SK/hv-shotdiff.sh" --export "$evd/result.xcresult" "$evd/shots" "$@" 2>&1 | tail -1
  return "${PIPESTATUS[0]}"
}

# log du faux serveur : nombre de requêtes d'un chemin (méthode facultative)
log_count() { curl -fsS "$URL/_hv/log" | python3 -I -c "
import json, sys
path, method = sys.argv[1], sys.argv[2]
print(sum(1 for e in json.load(sys.stdin) if (not path or e['p'] == path) and (not method or e['m'] == method)))" "$1" "${2:-}"; }

# routes de contrat reçues par le faux serveur (les routes /_hv/ de contrôle sont écartées), dans l'ordre
log_routes() { curl -fsS "$URL/_hv/log" | python3 -I -c "
import json, sys
for e in json.load(sys.stdin):
    if not e['p'].startswith('/_hv/'): print(e['m'], e['p'])"; }
