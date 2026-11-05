#!/usr/bin/env bash
# hv-run.sh — point d'entrée unique, non interactif, pour ${HV_RUNNER_DIR}. Modèle : aucun.
# Usage :
#   hv-run.sh api   [orb|fake]   # contrats API seuls (pas d'app) ; orb ajoute les scénarios du spike — modèle : aucun
#   hv-run.sh ui    [orb|fake]   # passe complète XCUITest + captures + réseau — modèle : aucun
#   hv-run.sh daily [orb|fake]   # test quotidien A11 (13 h 00 Paris) + rapport — modèle : aucun
#   hv-run.sh compat             # 3 tests de compatibilité A7 sur le faux serveur
# Variables : HV_WORK (défaut ~/hermed-bots-work, dossier dédié A12),
#   HV_XCTESTRUN (fichier .xctestrun produit par build-for-testing), HV_APP_BUNDLE_ID,
#   HV_TEST_API_KEY (secret, mode orb), HV_UNDER_RUNNER=1 si lancé par runner.sh (qui tient déjà .lock).
#   HV_BASELINES (défaut ../baselines, remplacé par les références temporaires du selftest).
#   HV_UI_PLAN (ui-core | ui-full, défaut ui-full) : filtre XCUITest aligné sur la Feature Map.
# Codes de sortie :
#   0 PASS | 2 usage | 3 PAUSE présent (rien lancé) | 4 verrou pris (rien lancé)
#   10 au moins un contrat/test FAIL | 11 écart visuel > tolérance | 14 connexion interdite
#   12 référence manquante | 13 comparateur absent ou en erreur
#   15 capture attendue absente du xcresult (ou aucune capture)
#   20 chemin protégé modifié (ARRÊT) | 21 chemin protégé présent avant passe | 22 cible ${HV_PROTECTED_HOST}
#   30-34 environnement Hermes (voir hv-hermes-env.sh) | 40 xcodebuild introuvable / xctestrun absent
# Les preuves survivent au nettoyage : $HV_WORK/evidence/<mode>-<AAAAMMJJ-HHMMSS>/
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-}; ENVMODE=${2:-fake}; REQUESTED_ENV=$ENVMODE; FALLBACK=aucun
ENV_STARTED=0; NOT_RUN=
RUNNER=${HV_RUNNER_DIR:?HV_RUNNER_DIR requis}
WORK=${HV_WORK:-$HOME/hermed-bots-work}
STAMP=$(TZ=Europe/Paris date +%Y%m%d-%H%M%S)
case "$ENVMODE" in orb|fake) ;; *) echo "environnement inconnu : $ENVMODE" >&2; exit 2 ;; esac
case "$MODE" in api|ui|daily|compat) ;; *) sed -n '2,20p' "$0" >&2; exit 2 ;; esac

[ -e "$RUNNER/PAUSE" ] && { echo "PAUSE présent ($RUNNER/PAUSE) : rien lancé"; exit 3; }
if [ "${HV_UNDER_RUNNER:-0}" != 1 ] && [ -d "$RUNNER/.lock" ]; then echo "verrou runner pris : rien lancé"; exit 4; fi
mkdir -p "$WORK/evidence"
LOCKD="$WORK/.hv-lock"
mkdir "$LOCKD" 2>/dev/null || { echo "verrou $LOCKD pris (passe en cours ou crash : supprimer à la main)"; exit 4; }

export HV_EVIDENCE; HV_EVIDENCE=$(mktemp -d "$WORK/evidence/$MODE-$STAMP-XXXXXX") || { rmdir "$LOCKD"; exit 10; }
LOG="$HV_EVIDENCE/run.log"; exec > >(tee -a "$LOG") 2>&1
T0=$(date +%s); RC=0; GUARD="non contrôlés"
note() { printf '[%s Paris] %s\n' "$(TZ=Europe/Paris date +%H:%M:%S)" "$*"; }
worst() { [ "$1" -gt "$RC" ] && RC=$1; return 0; }

stop_env() {
  if [ "$ENV_STARTED" = 1 ]; then
    "$HERE/hv-hermes-env.sh" down "$ENVMODE" >/dev/null 2>&1 || worst 10
    ENV_STARTED=0
  fi
}

# shellcheck disable=SC2329,SC2317
cleanup() {
  stop_env
  if [ -f "$HV_EVIDENCE/guard-before.txt" ]; then
    if "$HERE/hv-guard.sh" check "$HV_EVIDENCE/guard-before.txt" > "$HV_EVIDENCE/guard-after.txt" 2>&1; then GUARD="inchangés"
    else GUARD="MODIFIÉS"; RC=20; fi
  fi
  rmdir "$LOCKD" 2>/dev/null || true
}

trap 'RC=130; exit "$RC"' INT TERM HUP
trap 'finish' EXIT

fixture_for() { echo "$HERE/../fixtures/hermes-${1:-current}/contract.json"; }
start_env() {
  # Refuse to adopt a pre-existing environment; teardown owns only this run
  if [ "$ENVMODE" = orb ] && [ -n "$(docker ps -aq --filter "name=^${HV_CONTAINER:-hv-hermes-test}$")" ]; then
    note "conteneur déjà présent : ${HV_CONTAINER:-hv-hermes-test}"; return 33
  fi
  ENV_STARTED=1
  "$HERE/hv-hermes-env.sh" up "$ENVMODE"
}
URL() { echo "http://127.0.0.1:${HV_PORT:-18642}"; }

run_api() {
  start_env || { worst $?; return; }
  local pcmd=()  # ${pcmd[@]+…} : Bash 3.2 refuse un tableau vide sous set -u ; orb : `docker exec` tient lieu du canal SSH en lecture seule de la décision S6
  [ "$ENVMODE" = orb ] && pcmd=(--profile-cmd "docker exec -u ${HV_HERMES_USER:-hermes} -e HOME=${HV_HERMES_HOME:-/opt/data} ${HV_CONTAINER:-hv-hermes-test}")
  [ "$MODE" = daily ] && pcmd+=(--acceptance)
  python3 "$HERE/hv-contract-check.py" --url "$(URL)" --fixture "$(fixture_for "${HV_FAKE_VERSION:-current}")" --out "$HV_EVIDENCE/contracts.json" ${pcmd[@]+"${pcmd[@]}"} &
  local checker=$!
  if [ "$MODE" = daily ]; then
    "$HERE/hv-netwatch.sh" "$checker" 1 "$HV_EVIDENCE/net.txt" "${HV_PORT:-18642}" > "$HV_EVIDENCE/netwatch.log" 2>&1; worst $?
  fi
  wait "$checker" || worst 10
  if [ "$ENVMODE" = orb ]; then  # scénarios S1 à S7 du spike (coupure réseau, annulation d'un outil) en plus des contrats
    python3 "$HERE/hv-spike-probe.py" --url "$(URL)" --out "$HV_EVIDENCE/spike.json"; worst $?
  fi
  "$HERE/hv-guard.sh" check "$HV_EVIDENCE/guard-before.txt" || worst 20  # contrôle intermédiaire
}

run_compat() {
  local original_env=$ENVMODE case_ result rc
  ENVMODE=fake
  for case_ in "previous normal" "current fields" "current drop-route"; do
    # shellcheck disable=SC2086
    set -- $case_
    ENV_STARTED=1
    HV_FAKE_VERSION=$1 HV_FAKE_MODE=$2 HV_DROP=set_model "$HERE/hv-hermes-env.sh" up fake || { worst 34; break; }
    result="$HV_EVIDENCE/compat-$1-$2.json"
    python3 "$HERE/hv-contract-check.py" --url "$(URL)" --fixture "$(fixture_for "$1")" --out "$result"; rc=$?
    python3 - "$result" "$2" "$rc" <<'PYCOMPAT' || worst 10
import json, sys
path, mode, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = json.load(open(path))
fails = [r for r in rows if r["result"] == "FAIL"]
if mode == "drop-route" and rc == 10 and len(fails) == 1 and fails[0]["contract"] == "set_model" and "status=404" in fails[0]["detail"]:
    fails[0].update(result="PASS", detail="route retirée détectée, autres contrats disponibles; " + fails[0]["detail"])
    rc = 0
elif mode == "drop-route":
    rows.append(dict(contract="route-removed", result="FAIL", detail="set_model seul doit échouer en 404"))
    rc = 10
json.dump(rows, open(path, "w"), ensure_ascii=False, indent=2)
sys.exit(rc)
PYCOMPAT
    note "compat $1/$2 : contrôlée"
    stop_env
    "$HERE/hv-guard.sh" check "$HV_EVIDENCE/guard-before.txt" || { worst 20; break; }
  done
  stop_env
  ENVMODE=$original_env
}

run_daily() {
  if [ "${HV_USER_PRESENT:-1}" != 1 ]; then
    NOT_RUN="utilisateur absent (HV_USER_PRESENT=${HV_USER_PRESENT})"; return
  fi
  if [ "$ENVMODE" = orb ] && { ! command -v orb >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; }; then
    ENVMODE=fake; FALLBACK="OrbStack absent ou arrêté : repli fake"
    note "$FALLBACK"
  fi
  if [ "$ENVMODE" = fake ] && [ -z "${HV_TEST_API_KEY:-}" ]; then
    HV_TEST_API_KEY=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))'); export HV_TEST_API_KEY
  fi
  run_api
  [ -f "$HV_EVIDENCE/env.json" ] && cp "$HV_EVIDENCE/env.json" "$HV_EVIDENCE/env-primary.json"
  stop_env
  [ "$RC" = 20 ] && return
  run_compat
}

run_ui() {
  # shellcheck disable=SC2015
  command -v xcodebuild >/dev/null 2>&1 && [ -f "${HV_XCTESTRUN:-/nonexistent}" ] || { note "xcodebuild ou HV_XCTESTRUN absent"; worst 40; return; }
  note "UI backend=${HV_UI_BACKEND:-$ENVMODE}"
  case "${HV_UI_BACKEND:-$ENVMODE}" in
    orb)
      python3 "$HERE/hv-vm-ui.py" guest "$HV_EVIDENCE" "$HV_XCTESTRUN"; worst $?
      ;;
    fake)
      ENVMODE=fake
      if [ -z "${HV_TEST_API_KEYS:-}" ]; then
        HV_TEST_API_KEYS=$(python3 - "$(fixture_for current)" <<'PYKEYS'
import json, secrets, sys
print(json.dumps({profile: secrets.token_urlsafe(32) for profile in json.load(open(sys.argv[1]))["profiles"]["served"]}))
PYKEYS
        ) || { worst 32; return; }
      fi
      export HV_TEST_API_KEYS
      start_env || { worst $?; return; }
      TR_ENV=(TEST_RUNNER_HV_TEST_MODE=1 TEST_RUNNER_HV_TEST_API_KEYS="$HV_TEST_API_KEYS" TEST_RUNNER_HV_API_URL="$(URL)" TEST_RUNNER_HV_SHOTS="$HV_EVIDENCE/shots")
      [ -n "${HV_TEST_PROFILE_TABLE:-}" ] && TR_ENV+=(TEST_RUNNER_HV_TEST_PROFILE_TABLE="$HV_TEST_PROFILE_TABLE")
      UI_ONLY=()
      case "${HV_UI_PLAN:-ui-full}" in
        ui-core)
          UI_ONLY=(-only-testing:HermedBotsUITests/SixActions -only-testing:HermedBotsUITests/LaunchTests -only-testing:HermedBotsUITests/HD12Video)
          note "UI plan=ui-core (SixActions LaunchTests HD12Video)"
          ;;
        ui-full|none|"") note "UI plan=ui-full" ;;
        *) note "HV_UI_PLAN inconnu : ${HV_UI_PLAN} (ui-core ou ui-full)"; worst 2; return ;;
      esac
      env "${TR_ENV[@]}" \
      xcodebuild test-without-building -xctestrun "$HV_XCTESTRUN" -destination 'platform=macOS' \
        ${UI_ONLY[@]+"${UI_ONLY[@]}"} \
        -resultBundlePath "$HV_EVIDENCE/result.xcresult" > "$HV_EVIDENCE/xcodebuild.log" 2>&1; worst $(( $? ? 10 : 0 ))
      ;;
    *) note "HV_UI_BACKEND doit valoir orb ou fake"; worst 2; return ;;
  esac
  # le runner XCUITest est sandboxé : il ne peut pas écrire dans run.log, ses lignes HV-* passent par xcodebuild.log
  grep -E 'HV-(PERF|LAUNCH|LANG|RELAUNCH|SHOT) ' "$HV_EVIDENCE/xcodebuild.log" || true
  APPPID=$(pgrep -nf "${HV_APP_BUNDLE_ID:-HermedBotsTest}" || true)
  [ -n "$APPPID" ] && { "$HERE/hv-netwatch.sh" "$APPPID" 5 "$HV_EVIDENCE/net.txt"; worst $?; }
  # même raison : HVShot n'écrit pas dans shots/. Les captures sont les pièces jointes du xcresult ; chaque ligne HV-SHOT en annonce une
  shots=(); while read -r name; do shots+=("$name"); done < <(grep -o 'HV-SHOT [^ ]*' "$HV_EVIDENCE/xcodebuild.log" | cut -d' ' -f2 | sort -u)
  "$HERE/hv-shotdiff.sh" --export "$HV_EVIDENCE/result.xcresult" "$HV_EVIDENCE/shots" ${shots[@]+"${shots[@]}"}; s=$?; worst "$s"
  mkdir -p "$HV_EVIDENCE/reference-shots"
  for shot in "$HV_EVIDENCE/shots"/*.png; do
    [ -f "$shot" ] || continue
    case "${shot##*/}" in
      hd12-video-00[0-5].png) ;;
      hd12-video-*.png) continue ;;
    esac
    cp "$shot" "$HV_EVIDENCE/reference-shots/" || worst 15
  done
  # Tolérance visuelle : orb 3 % (drift Hermes réel vs baselines fake), fake/autres 2 %.
  case "${HV_UI_BACKEND:-$ENVMODE}" in
    orb) SHOT_TOL=0.03 ;;
    *) SHOT_TOL=0.02 ;;
  esac
  "$HERE/hv-shotdiff.sh" "$HV_EVIDENCE/reference-shots" "${HV_BASELINES:-$HERE/../baselines}" "$HV_EVIDENCE/diffs" "$SHOT_TOL"; s=$?; worst "$s"
}

# shellcheck disable=SC2329,SC2317
finish() {
  trap - EXIT
  cleanup
  DUR=$(( $(date +%s) - T0 ))
if [ "$MODE" = daily ]; then
  python3 - "$HV_EVIDENCE" "$DUR" "$GUARD" "$RC" "$NOT_RUN" "$REQUESTED_ENV" "$ENVMODE" "$FALLBACK" <<'PY' || worst 10
import json, sys, os, datetime, zoneinfo, glob
evd, dur, guard, rc = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
not_run, requested, envmode, fallback = sys.argv[5:]
now = datetime.datetime.now(zoneinfo.ZoneInfo("Europe/Paris"))
try: res = json.load(open(os.path.join(evd, "contracts.json")))
except Exception: res = []
try: res += json.load(open(os.path.join(evd, "spike.json")))  # sondes du spike, mode orb seulement
except Exception: pass
for path in sorted(glob.glob(os.path.join(evd, "compat-*.json"))):
    for row in json.load(open(path)):
        res.append(dict(row, contract=os.path.basename(path)[:-5] + ":" + row["contract"]))
if not not_run:
    res.append(dict(contract="netwatch", result="PASS" if os.path.exists(os.path.join(evd, "netwatch.log")) and "NET OK" in open(os.path.join(evd, "netwatch.log")).read() else "FAIL", detail="voir netwatch.log"))
ver = next((r["detail"].split()[0].removeprefix("version=") for r in res if r["contract"] == "version"), "inconnue")
try:
    if envmode == "orb": ver = json.load(open(os.path.join(evd, "env-primary.json"))).get("version", ver)
except Exception: pass
fails = [r for r in res if r["result"] == "FAIL"]
L = ["# Test quotidien Hermes : %s (heure de Paris)" % now.strftime("%Y-%m-%d %H:%M"), "",
     "- Version Hermes : %s" % ver, "- Environnement : %s (demandé : %s)" % (envmode, requested), "- Repli : %s" % fallback, "- Durée : %d s" % dur, "- Chemins protégés : %s" % guard,
     "- Code de sortie : %d" % rc, "- Verdict : %s" % ("not run : " + not_run if not_run else ("PASS" if rc == 0 else "FAIL")), "", "| Contrat | Résultat | Détail |", "|---|---|---|"]
L += ["| %s | %s | %s |" % (r["contract"], r["result"], r["detail"].replace("|", "/")) for r in res]
L += ["", "## Écarts", ""] + (["- %s : %s" % (r["contract"], r["detail"]) for r in fails] or ["- aucun"])
open(os.path.join(evd, "rapport-quotidien.md"), "w").write("\n".join(L) + "\n")
if (rc != 0 and not not_run) or fails or guard == "MODIFIÉS":
    open(os.path.join(evd, "ALERTE"), "w").write("FAIL ou chemin protégé modifié : voir rapport-quotidien.md\n")
PY
fi
  note "fin : code $RC, durée ${DUR}s, chemins protégés : $GUARD, preuves : $HV_EVIDENCE"
  exit "$RC"
}

note "hv-run $MODE ($ENVMODE) -> $HV_EVIDENCE"
"$HERE/hv-guard.sh" snapshot "$HV_EVIDENCE/guard-before.txt"; g=$?
if [ $g -ne 0 ]; then NOT_RUN="garde préalable refusée (code $g)"; RC=$g; exit "$RC"; fi
"$HERE/hv-guard.sh" target "${HV_TARGET_HOST:-localhost}" || { NOT_RUN="cible refusée"; RC=22; exit "$RC"; }


case "$MODE" in
  api) run_api ;;
  daily) run_daily ;;
  compat) run_compat ;;
  ui) run_ui ;;
esac
exit "$RC"
