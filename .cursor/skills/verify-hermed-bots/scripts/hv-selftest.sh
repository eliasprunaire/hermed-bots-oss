#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2012  # ok/ko ne peuvent pas échouer ; ls sur un chemin maîtrisé
# hv-selftest.sh — auto-tests Linux/macOS des scripts (sans app, sans OrbStack). Modèle : aucun.
# Usage : hv-selftest.sh   ; code 0 si tout passe, 1 sinon.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); fail=0
ok() { echo "PASS $*"; }; ko() { echo "FAIL $*"; fail=1; }
T=$(mktemp -d); export HOME="$T/home"; mkdir -p "$HOME"
G="$HERE/hv-guard.sh"
"$G" snapshot "$T/b" >/dev/null && ok "guard: snapshot HOME vide" || ko "guard snapshot"
"$G" check "$T/b" >/dev/null && ok "guard: inchangé => 0" || ko "guard inchangé"
mkdir -p "$HOME/.local/bin"; echo x > "$HOME/.local/bin/hermes"
"$G" check "$T/b" >/dev/null 2>&1; [ $? -eq 20 ] && ok "guard: apparition => 20" || ko "guard apparition"
"$G" snapshot "$T/b2" >/dev/null 2>&1; [ $? -eq 21 ] && ok "guard: présent avant => 21" || ko "guard présent"
HV_ALLOW_PREEXISTING=1 "$G" snapshot "$T/b3" >/dev/null 2>&1
touch -d '2001-01-01' "$HOME/.local/bin/hermes" 2>/dev/null || touch -t 200101010000 "$HOME/.local/bin/hermes"
"$G" check "$T/b3" >/dev/null 2>&1; [ $? -eq 20 ] && ok "guard: mtime changé => 20" || ko "guard mtime"
HV_ALLOW_PREEXISTING=1 "$G" snapshot "$T/b4" >/dev/null 2>&1; echo y > "$HOME/.local/bin/hermes"; touch -t 200101010000 "$HOME/.local/bin/hermes"
"$G" check "$T/b4" >/dev/null 2>&1; [ $? -eq 20 ] && ok "guard: contenu changé (même mtime) => 20" || ko "guard hash"
rm -rf "$HOME/.local"; mkdir -p "$HOME/.hermes/hermes-agent/sub"
HV_ALLOW_PREEXISTING=1 "$G" snapshot "$T/b5" >/dev/null 2>&1; touch "$HOME/.hermes/hermes-agent/sub/new"
"$G" check "$T/b5" >/dev/null 2>&1; [ $? -eq 20 ] && ok "guard: fichier ajouté dans le dossier => 20" || ko "guard dossier"
"$G" target HV_PROTECTED_HOST.invalid >/dev/null 2>&1; [ $? -eq 22 ] && ok "guard: jeton HV_PROTECTED_HOST refusé => 22" || ko "guard target"
"$G" target hv-hermes-test >/dev/null && ok "guard: conteneur de test accepté" || ko "guard target ok"
"$G" bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "guard: usage invalide => 2" || ko "guard usage"
rm -rf "$HOME/.hermes"

# Fixtures (HD-02) : les deux versions portent les onze contrats au format observé par le spike ; décisions S4 (chat de session) et S6 (liste SSH)
python3 -I - "$HERE/../fixtures" <<'PY' && ok "fixtures: onze contrats, chat de session pour send_message, liste SSH en lecture seule, événements et bords observés (current et previous)" || ko "fixtures: forme invalide (voir la ligne ci-dessus)"
import json, re, sys
NAMES = {"version", "list_profiles", "profile_served", "list_sessions", "new_session", "send_message", "start_run", "run_events", "set_model", "approve", "cancel_run"}
EDGES = {"message-vide", "run-inexistant", "id-negatif", "json-invalide", "cle-absente"}
loaded = {}
for v in ("current", "previous"):
    path = "%s/hermes-%s/contract.json" % (sys.argv[1], v)
    raw = open(path, encoding="utf-8").read()
    assert "VÉRIFIER" not in raw, "%s: marqueur de supposition encore présent" % v
    C = loaded[v] = json.loads(raw)
    assert set(C["contracts"]) == NAMES, "%s: contrats %s" % (v, sorted(set(C["contracts"]) ^ NAMES))
    assert re.fullmatch(r"\d+\.\d+\.\d+", C["version"]) and C["version"] == C["contracts"]["version"]["response"]["version"], "%s: version incohérente" % v
    assert C["optional_fields"] and C["profiles"]["served"], "%s: optional_fields ou profiles absents" % v
    for name, c in C["contracts"].items():
        if c.get("transport") == "ssh": continue  # list_profiles : vérifié plus bas
        assert c.get("method") in ("GET", "POST") and str(c.get("path", "")).startswith("/") and c.get("response"), "%s/%s: méthode, chemin ou réponse manquant" % (v, name)
        assert set(re.findall(r"\{(\w+)\}", c["path"])) <= {"profile", "session", "run"}, "%s/%s: variable de chemin inconnue" % (v, name)
        assert c["response"] == "SSE" or isinstance(c.get("status"), int), "%s/%s: statut attendu absent" % (v, name)
    lp, sm = C["contracts"]["list_profiles"], C["contracts"]["send_message"]
    assert lp["transport"] == "ssh" and lp["read_only"] and lp["command"] == ["hermes", "profile", "list"], "%s: list_profiles doit être la commande SSH en lecture seule" % v
    shown = [l.replace("\u25c6", " ").split() for l in lp["output"].splitlines() if any(ch.isalnum() for ch in l) and not l.split()[0] == "Profile"]
    assert {t[0] for t in shown if t[2] != lp["stopped_gateway"]} == set(C["profiles"]["served"]) and {t[0] for t in shown if t[2] == lp["stopped_gateway"]} == set(C["profiles"]["stopped"]) == {"hv-old"}, "%s: la table ne correspond pas à profiles.served et profiles.stopped" % v
    assert sm["path"].endswith("/api/sessions/{session}/chat") and sm["repeat"] >= 2 and sm["expect_locked"]["runtime.route_source"] == "session_model_lock", "%s: send_message doit passer par le chat de session, deux messages, verrou vérifié" % v
    assert C["contracts"]["start_run"]["path"].endswith("/v1/runs") and list(C["contracts"]).index("set_model") < list(C["contracts"]).index("send_message"), "%s: start_run absent ou set_model après send_message" % v
    names = [e["event"] for e in C["events"]]
    assert all("type" not in e for e in C["events"]) and "hv.unknown_future_event" in names and names[-1] == "run.completed", "%s: événements %s" % (v, names)
    assert EDGES <= {e["name"] for e in C["edges"]} and all(isinstance(e["status"], int) and e["path"].startswith("/") for e in C["edges"]), "%s: bords" % v
assert loaded["current"]["contracts"]["approve"]["body"] != loaded["previous"]["contracts"]["approve"]["body"], "previous doit porter le corps d'approbation de sa version"
PY

# Faux serveur + contrats + modes A7
export HV_EVIDENCE="$T/evd" HV_PORT=$((20000 + RANDOM % 20000)); export HV_TEST_API_KEY="selftest-$RANDOM"
E="$HERE/hv-hermes-env.sh"; C="$HERE/hv-contract-check.py"; F="$HERE/../fixtures"
for m in normal fields drop-route down; do
  HV_FAKE_MODE=$m "$E" up fake >/dev/null || { ko "fake up $m"; continue; }
  python3 "$C" --url "http://127.0.0.1:$HV_PORT" --fixture "$F/hermes-current/contract.json" --out "$T/r-$m.json" --timeout 3 >/dev/null; rc=$?
  case $m in
    normal) [ $rc -eq 0 ] && ok "fake normal: tous les contrats et toutes les sondes de bord PASS" || ko "fake normal (rc=$rc)" ;;
    fields) grep -q zz_new_field "$T/r-$m.json" && grep -q "default=\['session.title'\]" "$T/r-$m.json" && [ $rc -eq 0 ] && ok "fake fields: champ ajouté signalé, champ facultatif retiré = défaut, tout PASS (A7)" || ko "fake fields (rc=$rc)" ;;
    drop-route) python3 -c "import json,sys;r=json.load(open('$T/r-$m.json'));f=[x for x in r if x['result']=='FAIL'];sys.exit(not(len(f)==1 and f[0]['contract']=='set_model' and 'status=404' in f[0]['detail']))" && ok "fake drop-route: set_model seul FAIL en 404" || ko "fake drop-route" ;;
    down) python3 -c "import json,sys;r=json.load(open('$T/r-$m.json'));sys.exit(not(r and all(x['result']=='FAIL' and 'status=503' in x['detail'] for x in r)))" && [ $rc -eq 10 ] && ok "fake down: tout FAIL en 503 sans plantage" || ko "fake down" ;;
  esac
  "$E" down fake >/dev/null
done
# Contrôles négatifs : une liste `data` à null, en chaîne ou à élément sans id, un profil arrêté listé comme actif, un verrou de modèle ignoré
for k in null string noid leak nolock; do
  HV_FAKE_MODE=malformed HV_MALFORMED=$k "$E" up fake >/dev/null || { ko "fake up malformed $k"; continue; }
  python3 "$C" --url "http://127.0.0.1:$HV_PORT" --fixture "$F/hermes-current/contract.json" --out "$T/r-bad-$k.json" --timeout 3 >/dev/null; rc=$?
  case $k in null|string|noid) want="profile_served list_sessions" ;; leak) want="list_profiles" ;; nolock) want="send_message" ;; esac
  python3 -c "import json,sys;f=sorted(x['contract'] for x in json.load(open('$T/r-bad-$k.json')) if x['result']=='FAIL');sys.exit(f!=sorted('$want'.split()))" && [ $rc -eq 10 ] && ok "fake malformed $k: FAIL sur $want seulement, code 10" || ko "fake malformed $k (rc=$rc)"
  "$E" down fake >/dev/null
done
HV_FAKE_VERSION=previous "$E" up fake >/dev/null || ko "fake up previous"
python3 "$C" --url "http://127.0.0.1:$HV_PORT" --fixture "$F/hermes-previous/contract.json" --out "$T/r-previous.json" --timeout 3 >/dev/null; rc=$?
[ $rc -eq 0 ] && ok "fake previous: tous les contrats et toutes les sondes de bord PASS" || ko "fake previous (rc=$rc)"
python3 "$C" --url "http://127.0.0.1:$HV_PORT" --fixture "$F/hermes-current/contract.json" --out "$T/r-cross.json" --timeout 3 >/dev/null; rc=$?
python3 -c "import json,sys;r={x['contract']:x['result'] for x in json.load(open('$T/r-cross.json'))};sys.exit(not(r['approve']=='FAIL' and r['cancel_run']=='PASS' and r['version']=='PASS'))" && [ $rc -eq 10 ] && ok "fake previous: la fixture current échoue sur approve (corps d'approbation de 0.22.1)" || ko "fake previous contre fixture current (rc=$rc)"
"$E" down fake >/dev/null
HV_FAKE_MODE=normal "$E" up fake >/dev/null
AUTH="Authorization: Bearer $HV_TEST_API_KEY"; BASE="http://127.0.0.1:$HV_PORT/p/hv-bot-a"
RID=$(curl -fsS -H "$AUTH" -d '{"input":"hv"}' "$BASE/v1/runs" | python3 -c "import json,sys;print(json.load(sys.stdin)['run_id'])")
curl -fsS -X POST -d '{"event":"hv.injected"}' "http://127.0.0.1:$HV_PORT/_hv/inject" >/dev/null
curl -fsS -H "$AUTH" "$BASE/v1/runs/$RID/events" | grep -q hv.injected && ok "fake: événement injecté dans le flux" || ko "fake inject"
n=$(curl -fsS -H "$AUTH" -H 'Last-Event-ID: 5' "$BASE/v1/runs/$RID/events" | grep -c '^id:')
[ "$n" = 3 ] && ok "fake: Last-Event-ID reprend après l'identifiant demandé (3 événements restants sur 9)" || ko "fake Last-Event-ID ($n événements)"
curl -fsS -H "$AUTH" "$BASE/v1/runs/$RID/events" | grep -q '^: stream closed' && ok "fake: le flux se ferme après : stream closed" || ko "fake stream closed"
curl -fsS -X POST -d '{"seconds":2}' "http://127.0.0.1:$HV_PORT/_hv/cut" >/dev/null
st=$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" "$BASE/api/sessions")
[ "$st" = 503 ] && ok "fake: coupure simulée => 503" || ko "fake cut ($st)"
"$E" down fake >/dev/null
grep -rq "$HV_TEST_API_KEY" "$T/evd" && ko "secret retrouvé dans les preuves" || ok "secret absent des preuves"

# Sonde HD-01 : contre le faux serveur, aucune sonde ne plante ; celles qui lisent le conteneur (--no-docker) échouent
HV_FAKE_MODE=normal "$E" up fake >/dev/null
python3 "$HERE/hv-spike-probe.py" --url "http://127.0.0.1:$HV_PORT" --out "$T/spike.json" --timeout 3 --no-docker >/dev/null 2>&1; rc=$?
python3 -c "import json,sys;r=json.load(open('$T/spike.json'));sys.exit(not(len(r)>=8 and not any('crash' in x['detail'] for x in r) and {x['contract'] for x in r if x['result']=='FAIL'}>={'S2:network_cut','S3:cancel_run','S6:list_profiles'}))" && [ $rc -eq 10 ] && ok "spike-probe: faux serveur => aucun plantage, sondes docker en FAIL, code 10" || ko "spike-probe faux serveur (rc=$rc)"
"$E" down fake >/dev/null

# Relais orb : refus de tout montage hôte, sans OrbStack (shims docker et orb)
SH="$T/shim"; mkdir -p "$SH"; : > "$T/docker.log"
cat > "$SH/docker" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$SHIM_LOG"
case "$1" in
  inspect) case "$*" in *Mounts*) printf '%s\n' "$SHIM_MOUNT" ;; *Labels*) echo verify-hermed-bots ;; *Running*) echo true ;; esac ;;
  build) [ -z "${SHIM_BUILD_FAIL:-}" ] || exit 1 ;;
  run) echo fakeid ;;
esac
exit 0
SHIM
printf '#!/usr/bin/env bash\nexit 0\n' > "$SH/orb"; chmod +x "$SH/docker" "$SH/orb"
ORBKEY="selftest-orb-key-$RANDOM$RANDOM"
for mnt in 'bind /opt/example/.hermes' 'bind /opt/example/.local/bin' 'bind /opt/example/project'; do
  : > "$T/docker.log"
  PATH="$SH:$PATH" SHIM_LOG="$T/docker.log" SHIM_MOUNT="$mnt" HV_TEST_API_KEY="$ORBKEY" HV_EVIDENCE="$T/evd-orb" "$E" up orb >/dev/null 2>&1; rc=$?
  [ $rc -eq 31 ] && grep -q 'rm -f -v hv-hermes-test' "$T/docker.log" && ok "orb relais: montage '$mnt' refusé => 31, conteneur retiré" || ko "orb relais montage '$mnt' (rc=$rc)"
done
grep -q "$ORBKEY" "$T/docker.log" && ko "orb relais: la clé apparaît dans les arguments de docker" || ok "orb relais: clé absente des arguments de docker"
grep '^run ' "$T/docker.log" | grep -Eq '(^| )(-v|--mount)( |$)' && ko "orb relais: -v ou --mount passé à docker" || ok "orb relais: aucun -v ni --mount"
# Q11 : latest à chaque passe, donc l'image dérivée se reconstruit avec une base tirée même quand elle existe déjà
: > "$T/docker.log"; PATH="$SH:$PATH" SHIM_LOG="$T/docker.log" SHIM_MOUNT='bind /x/.hermes' HV_TEST_API_KEY="$ORBKEY" HV_EVIDENCE="$T/evd-orb" "$E" up orb >/dev/null 2>&1
grep -Eq '^build .*--pull .*hv-hermes:spike' "$T/docker.log" && ok "orb up: image reconstruite avec --pull même si elle existe" || ko "orb up: pas de build --pull de l'image existante"
: > "$T/docker.log"; PATH="$SH:$PATH" SHIM_LOG="$T/docker.log" SHIM_BUILD_FAIL=1 HV_TEST_API_KEY="$ORBKEY" HV_EVIDENCE="$T/evd-orb" "$E" up orb >/dev/null 2>&1; rc=$?
[ $rc -eq 35 ] && ! grep -q '^run ' "$T/docker.log" && ok "orb up: échec du build => 35, aucun conteneur lancé" || ko "orb up: échec du build (rc=$rc)"
: > "$T/docker.log"; PATH="$SH:$PATH" SHIM_LOG="$T/docker.log" SHIM_MOUNT='bind /x/.hermes' HV_HERMES_IMAGE=autre:img HV_TEST_API_KEY="$ORBKEY" HV_EVIDENCE="$T/evd-orb" "$E" up orb >/dev/null 2>&1
grep -q '^build ' "$T/docker.log" && ko "orb up: image personnalisée reconstruite" || ok "orb up: image personnalisée existante laissée telle quelle"
PATH="$SH:$PATH" SHIM_LOG="$T/docker.log" HV_TEST_API_KEY=court HV_EVIDENCE="$T/evd-orb" "$E" up orb >/dev/null 2>&1; [ $? -eq 32 ] && ok "orb relais: clé de moins de 16 caractères => 32" || ko "orb relais clé courte"

# Serveur minimal (S3 + santé) et shim docker : ps échoue après le stop, env.json écrit le champ lu par hv-run.sh
cat > "$T/stub.py" <<'PYSTUB'
import http.server, json, os, sys
S = {"stopped": False, "keys": set()}
CUT, FLAP = os.environ.get("STUB_CUT", "/nonexistent"), os.environ.get("STUB_FLAP", "/nonexistent")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _j(self, code, o, ct="application/json"):
        b = o if isinstance(o, bytes) else json.dumps(o).encode()
        self.send_response(code); self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = self.path
        if p == "/health":
            n = int(open(FLAP).read() or 0) if os.path.exists(FLAP) else 0
            if os.path.exists(CUT) or n > 0:  # coupure, puis refus transitoire après la reconnexion
                if n > 0 and not os.path.exists(CUT): open(FLAP, "w").write(str(n - 1))
                self.connection.close(); return
            return self._j(200, {"version": "9.9.9"})
        if p == "/health/detailed": return self._j(200, b'{"readiness": {"status": "ok"}}')
        if p.endswith("/messages"): return self._j(200, {"data": [{"role": "user"}, {"role": "assistant"}]})
        if p.endswith("/events") and "run_slow" in p:
            late = self.headers.get("Last-Event-ID") is not None
            return self._j(200, ('id:%d\ndata:%s\n\n' % (1 if late else 0, json.dumps({"event": "run.completed" if late else "message.delta", "seq": 1 if late else 0}))).encode(), "text/event-stream")
        if p.endswith("/events"):
            ev = "run.cancelled" if S["stopped"] else "tool.started"
            return self._j(200, ('id:0\ndata:%s\n\n' % json.dumps({"event": ev, "seq": 0})).encode(), "text/event-stream")
        if "/v1/runs/" in p: return self._j(200, {"status": "cancelled", "interrupted": True, "completed": False})
        return self._j(200, {"data": []})
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if b"HV_SLOW" in body:
            k = self.headers.get("Idempotency-Key"); seen = k in S["keys"]; S["keys"].add(k)
            return self._j(202, {"status": "started", "replayed": seen, "run_id": "run_slow"})
        if self.path.endswith("/stop"): S["stopped"] = True; return self._j(200, {"status": "stopping"})
        return self._j(202, {"status": "started", "replayed": False, "run_id": "run_x"})
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYSTUB
SP=$((20000 + RANDOM % 20000)); STUB_CUT="$T/cut" STUB_FLAP="$T/flap" python3 "$T/stub.py" "$SP" & STUB=$!; sleep 1
cat > "$SH/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  inspect) case "$*" in *Mounts*) echo ;; *Labels*) echo verify-hermed-bots ;; *Running*) echo true ;; esac ;;
  ps) ;;
  run) echo fakeid ;;
  network) case "$2" in disconnect) : > "$SHIM_CUT" ;; connect) echo 2 > "$SHIM_FLAP"; rm -f "$SHIM_CUT" ;; esac ;;
  exec) n=$(cat "$SHIM_N" 2>/dev/null || echo 0); echo $((n + 1)) > "$SHIM_N"
        if [ "$n" -lt "${SHIM_PS_OK:-1}" ]; then echo "1 0 00:01 sleep 300"; else echo "Cannot connect to the Docker daemon"; exit 1; fi ;;
esac
exit 0
SHIM
PATH="$SH:$PATH" HV_PORT=$SP HV_TEST_API_KEY="$ORBKEY" HV_EVIDENCE="$T/evd-orb2" "$E" up orb >/dev/null 2>&1
python3 -c "import json,sys;sys.exit(json.load(open('$T/evd-orb2/env.json')).get('version')!='9.9.9')" && ok "orb up: env.json porte le champ version lu par hv-run.sh" || ko "orb up: champ version absent de env.json"
: > "$T/n"; PATH="$SH:$PATH" SHIM_N="$T/n" SHIM_PS_OK=2 HV_TEST_API_KEY="$ORBKEY" python3 "$HERE/hv-spike-probe.py" --url "http://127.0.0.1:$SP" --out "$T/s3.json" --timeout 3 >/dev/null 2>&1
python3 -c "import json,sys;r={x['contract']:x for x in json.load(open('$T/s3.json'))}['S3:cancel_run'];sys.exit(not(r['result']=='FAIL' and 'docker' in r['detail']))" && ok "spike-probe S3: échec de docker exec ps => FAIL, pas PASS" || ko "spike-probe S3 accepte un ps en échec"
PATH="$SH:$PATH" SHIM_CUT="$T/cut" SHIM_FLAP="$T/flap" HV_TEST_API_KEY="$ORBKEY" python3 "$HERE/hv-spike-probe.py" --url "http://127.0.0.1:$SP" --out "$T/cut.json" --timeout 3 >/dev/null 2>&1
python3 -c "import json,sys;r={x['contract']:x for x in json.load(open('$T/cut.json'))}['S2:network_cut'];sys.exit(r['result']!='PASS')" && ok "spike-probe S2: refus transitoire après la reconnexion toléré" || ko "spike-probe S2:network_cut (refus transitoire)"
kill "$STUB" 2>/dev/null; wait "$STUB" 2>/dev/null

# Faux fournisseur de modèle (HD-05, lanes 4 et 7) : HV_LOOP répète le même appel d'outil après chaque résultat, puis s'arrête à la borne ; HV_TOOL_SLEEP et HV_TOOL_LONG restent à un seul appel (sleep 300, sleep 400)
python3 -I - "$HERE/../orb/fake-llm.py" 2>/dev/null <<'PY' && ok "fake-llm: HV_LOOP répète le même appel d'outil jusqu'à la borne, HV_TOOL_SLEEP et HV_TOOL_LONG un seul appel" || ko "fake-llm: HV_LOOP, HV_TOOL_SLEEP ou HV_TOOL_LONG"
import importlib.util, json, sys, threading, urllib.request
from http.server import ThreadingHTTPServer
sys.dont_write_bytecode = True  # pas de __pycache__ dans orb/
spec = importlib.util.spec_from_file_location("fake_llm", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
srv = ThreadingHTTPServer(("127.0.0.1", 0), m.Handler); threading.Thread(target=srv.serve_forever, daemon=True).start()
def turn(keyword):
    msgs, calls = [{"role": "user", "content": keyword + " go"}], []
    for _ in range(20):
        body = json.dumps({"model": "hv-fake-1", "messages": msgs, "tools": [{"function": {"name": "terminal"}}]}).encode()
        req = urllib.request.Request("http://127.0.0.1:%d/v1/chat/completions" % srv.server_port, body, {"Content-Type": "application/json"})
        answer = json.load(urllib.request.urlopen(req))["choices"][0]["message"]
        if not answer.get("tool_calls"):
            return calls, answer["content"]
        call = answer["tool_calls"][0]; calls.append(call["function"]["arguments"])
        msgs += [{"role": "assistant", "content": None, "tool_calls": [call]}, {"role": "tool", "tool_call_id": call["id"], "content": "ok"}]
    raise AssertionError(keyword + ": pas de fin")
calls, text = turn("HV_LOOP")
assert len(calls) == m.LOOP_CALLS and len(set(calls)) == 1 and text == "HV-FAKE-TOOL-DONE", (len(calls), set(calls), text)
calls, text = turn("HV_TOOL_SLEEP")
assert len(calls) == 1 and text == "HV-FAKE-TOOL-DONE", (len(calls), text)
calls, text = turn("HV_TOOL_LONG")
assert len(calls) == 1 and json.loads(calls[0])["command"] == "sleep 400" and text == "HV-FAKE-TOOL-DONE", (calls, text)
srv.shutdown()
PY

# Point d'entrée : PAUSE et verrou
R="$T/runner"; mkdir -p "$R"; touch "$R/PAUSE"
HV_RUNNER_DIR=$R HV_WORK="$T/work" "$HERE/hv-run.sh" api fake >/dev/null 2>&1; [ $? -eq 3 ] && ok "run: PAUSE => 3" || ko "run pause"
rm "$R/PAUSE"; mkdir "$R/.lock"
HV_RUNNER_DIR=$R HV_WORK="$T/work" "$HERE/hv-run.sh" api fake >/dev/null 2>&1; [ $? -eq 4 ] && ok "run: verrou runner => 4" || ko "run lock"
HV_UNDER_RUNNER=1 HV_RUNNER_DIR=$R HV_WORK="$T/work" "$HERE/hv-run.sh" daily fake >/dev/null 2>&1; rc=$?
rep=$(ls "$T"/work/evidence/daily-*/rapport-quotidien.md 2>/dev/null | head -1)
[ -n "$rep" ] && grep -q "Chemins protégés : inchangés" "$rep" && ok "run daily: rapport écrit, survit au nettoyage (rc=$rc)" || ko "run daily"
[ ! -d "$T/work/.hv-lock" ] && ok "run: verrou hv libéré" || ko "run hv-lock"
# Bash 3.2 (macOS) : un tableau vide développé sous set -u casse hv-run.sh api fake (unbound variable)
if [ -x /bin/bash ]; then
  HV_UNDER_RUNNER=1 HV_RUNNER_DIR=$R HV_WORK="$T/work" /bin/bash "$HERE/hv-run.sh" api fake >"$T/b32.log" 2>&1; rc=$?
  [ $rc -eq 0 ] && ls "$T"/work/evidence/api-*/contracts.json >/dev/null 2>&1 && [ ! -d "$T/work/.hv-lock" ] && ok "run: api fake sous /bin/bash $(/bin/bash -c 'echo $BASH_VERSION') => 0, contracts.json écrit, verrou libéré" || ko "run: api fake sous /bin/bash (rc=$rc) : $(tail -2 "$T/b32.log")"
fi
# Captures (HD-06) : le runner XCUITest est sandboxé, les PNG viennent des pièces jointes du xcresult ; aucune capture attendue manquante ne passe en silence
SD="$HERE/hv-shotdiff.sh"; mkdir -p "$T/shim" "$T/base"
cat > "$T/shim/xcrun" <<'SH'
#!/usr/bin/env bash
# simule `xcrun xcresulttool export attachments --path P --output-path O` : SHIM_ATTACH = noms séparés par des espaces
out=; while [ $# -gt 0 ]; do [ "$1" = --output-path ] && out=$2; shift; done
[ -n "${SHIM_FAIL:-}" ] && { echo "xcresulttool: bundle illisible" >&2; exit 1; }
mkdir -p "$out"; i=0; m=
for n in ${SHIM_ATTACH:-}; do
  i=$((i+1))
  if [ -n "${HV_STUB_PNG:-}" ]; then cp "$HV_STUB_PNG" "$out/FILE-$i.png"
  else printf 'png-%s' "$n" > "$out/FILE-$i.png"
  fi
  m="$m{\"attachments\":[{\"exportedFileName\":\"FILE-$i.png\",\"suggestedHumanReadableName\":\"${n}_0_UUID-$i.png\"}],\"testIdentifier\":\"T/t$i()\"},"
done
printf '[%s]' "${m%,}" > "$out/manifest.json"
SH
printf '#!/usr/bin/env bash\nprintf "HV-SHOT launch\\nHV-SHOT language-fr\\n"\nexit 0\n' > "$T/shim/xcodebuild"
chmod +x "$T/shim/xcrun" "$T/shim/xcodebuild"
mkdir -p "$T/caps-vide"
"$SD" "$T/caps-absent" "$T/base" "$T/diffs" >/dev/null 2>&1; [ $? -eq 15 ] && ok "shotdiff: dossier de captures absent => 15" || ko "shotdiff: dossier absent doit échouer"
"$SD" "$T/caps-vide" "$T/base" "$T/diffs" >/dev/null 2>&1; [ $? -eq 15 ] && ok "shotdiff: dossier sans PNG => 15" || ko "shotdiff: dossier vide doit échouer"
PATH="$T/shim:$PATH" SHIM_ATTACH="launch language-fr" "$SD" --export "$T/x.xcresult" "$T/caps-ok" launch language-fr >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && [ -f "$T/caps-ok/launch.png" ] && [ -f "$T/caps-ok/language-fr.png" ] && ok "export: pièces jointes copiées sous <nom>.png (suffixe _<n>_<UUID> retiré)" || ko "export: captures non copiées (rc=$rc)"
PATH="$T/shim:$PATH" SHIM_ATTACH="launch" "$SD" --export "$T/x.xcresult" "$T/caps-man" launch language-fr >"$T/exp.out" 2>&1; rc=$?
[ $rc -eq 15 ] && grep -q "language-fr" "$T/exp.out" && ok "export: capture attendue manquante => 15, nommée" || ko "export: capture manquante (rc=$rc) : $(cat "$T/exp.out")"
PATH="$T/shim:$PATH" SHIM_ATTACH="" "$SD" --export "$T/x.xcresult" "$T/caps-zero" >/dev/null 2>&1; [ $? -eq 15 ] && ok "export: aucune pièce jointe => 15" || ko "export: zéro capture doit échouer"
PATH="$T/shim:$PATH" SHIM_FAIL=1 "$SD" --export "$T/x.xcresult" "$T/caps-ko" launch >/dev/null 2>&1; [ $? -eq 15 ] && ok "export: xcresulttool en échec => 15" || ko "export: échec de xcresulttool masqué"
# passe ui bout en bout avec xcodebuild et xcrun simulés : HV-SHOT annonce deux captures
# PNG 1×1 identiques : Linux n'a pas les baselines versionnées ; compare exige un fichier image
python3 - "$T/pixel.png" <<'PY'
import pathlib, struct, sys, zlib
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
raw = b"\x00\x00\x00\x00"
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
pathlib.Path(sys.argv[1]).write_bytes(png)
PY
cp "$T/pixel.png" "$T/base/launch.png"
cp "$T/pixel.png" "$T/base/language-fr.png"
touch "$T/fake.xctestrun"; rm -rf "$T/work-ui"
HV_UNDER_RUNNER=1 HV_RUNNER_DIR=$R HV_WORK="$T/work-ui" HV_XCTESTRUN="$T/fake.xctestrun" PATH="$T/shim:$PATH" SHIM_ATTACH="launch" "$HERE/hv-run.sh" ui fake >"$T/ui1.log" 2>&1; rc=$?
[ $rc -eq 15 ] && ok "run ui: capture annoncée par HV-SHOT absente du xcresult => 15" || ko "run ui: capture manquante (rc=$rc) : $(tail -3 "$T/ui1.log")"
HV_UNDER_RUNNER=1 HV_RUNNER_DIR=$R HV_WORK="$T/work-ui" HV_XCTESTRUN="$T/fake.xctestrun" HV_BASELINES="$T/base" HV_STUB_PNG="$T/pixel.png" PATH="$T/shim:$PATH" SHIM_ATTACH="launch language-fr" "$HERE/hv-run.sh" ui fake >"$T/ui2.log" 2>&1; rc=$?
[ $rc -eq 0 ] && ls "$T"/work-ui/evidence/ui-*/shots/language-fr.png >/dev/null 2>&1 && ok "run ui: captures exportées dans shots/, passe => 0" || ko "run ui: captures complètes (rc=$rc) : $(tail -3 "$T/ui2.log")"
# Bash 3.2 : sans ligne HV-SHOT, le tableau des noms attendus est vide ; une passe sans aucune pièce jointe échoue encore
if [ -x /bin/bash ]; then
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/shim/xcodebuild"
  HV_UNDER_RUNNER=1 HV_RUNNER_DIR=$R HV_WORK="$T/work-ui" HV_XCTESTRUN="$T/fake.xctestrun" PATH="$T/shim:$PATH" SHIM_ATTACH="" /bin/bash "$HERE/hv-run.sh" ui fake >"$T/ui3.log" 2>&1; rc=$?
  [ $rc -eq 15 ] && ! grep -q "unbound" "$T/ui3.log" && ok "run ui sous /bin/bash $(/bin/bash -c 'echo $BASH_VERSION') : aucune capture ni annonce => 15, sans variable non définie" || ko "run ui: tableau vide sous Bash 3.2 (rc=$rc) : $(tail -3 "$T/ui3.log")"
fi

# a. pas de détail d'infrastructure concret dans la prose versionnée (types seulement)
python3 -I - "$HERE/.." <<'PY' && ok "docs: aucun détail d'infrastructure concret dans la prose" || ko "docs: détail d'infrastructure dans la prose"
import os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
banned = [
    (r"(?<!HV_)hv-ui-golden", "image"),
    (r"\btart\b", "hypervisor"),
    (r"com\.hv\.pf", "service"),
    (r"/etc/pf", "path"),
    (r"\bSIP\b", "security"),
    (r"Setup Assistant", "service"),
    (r"/opt/data", "path"),
    (r"/tmp/hv-doctor", "path"),
    (r"/Users(?:/|\b)", "path"),
    (r"Homebrew 3\.14", "tool"),
    (r"notify\.sh", "service"),
    (r"hv-ui-vm", "image"),
    (r"\bCLUF\b", "license"),
    (r"hv-hermes:spike", "image"),
    (r"hv-hermes-test(?!-data)", "host"),
    (r"nousresearch/hermes-agent", "image"),
    (r"(?<!\$\{)(?<!HV_PORT:-)(?<!HV_PORT.)\b18642\b", "port"),
    (r"(?<!\$\{HV_CONTAINER_PORT:-)\b8642\b", "port"),
]
guest = os.environ.get("HV_GUEST_ACCOUNT", "").strip()
if guest:
    banned.append((r"\b%s\b" % re.escape(guest), "account"))
hits = []
for path in list(root.glob("*.md")) + list(root.glob("**/*.md")) + list(root.glob("**/*.json")):
    text = path.read_text(encoding="utf-8")
    for rx, kind in banned:
        if re.search(rx, text):
            hits.append(kind)
if hits:
    sys.stderr.write("infra types: %s\n" % ",".join(sorted(set(hits))))
    sys.exit(1)
PY

# d. checklist Sparkle
grep -q "Mandatory after every Sparkle update" "$HERE/../SKILL.md" \
  && grep -q "single-copy pass" "$HERE/../SKILL.md" \
  && grep -q 'mdfind "kMDItemCFBundleIdentifier' "$HERE/../SKILL.md" \
  && ok "skill: checklist Sparkle obligatoire présente" || ko "skill: checklist Sparkle absente"

# b. --acceptance : même nom, même sémantique, mêmes codes (0 / 10 / 2)
python3 "$HERE/hv-contract-check.py" --help 2>/dev/null | grep -q -- "--acceptance" && ok "contract-check: --acceptance dans --help" || ko "contract-check: --acceptance absent de --help"
python3 "$HERE/hv-contract-check.py" --acceptance >/dev/null 2>&1; [ $? -eq 2 ] && ok "contract-check: --acceptance sans --url => 2" || ko "contract-check: usage --acceptance"
HV_FAKE_MODE=normal "$E" up fake >/dev/null || ko "fake up acceptance"
python3 "$HERE/hv-contract-check.py" --url "http://127.0.0.1:$HV_PORT" --fixture "$F/hermes-current/contract.json" --out "$T/r-acc.json" --acceptance --timeout 3 >/dev/null; rc=$?
python3 -c "import json,sys; r=json.load(open('$T/r-acc.json')); a=[x for x in r if x['contract'].startswith('acceptance:')]; t=[x for x in a if x['contract'].endswith(':tool')]; ap=[x for x in a if x['contract'].endswith(':approve')]; sys.exit(not (len(a)==54 and all(x['result']=='PASS' for x in a) and t and all('tool.started' in x['detail'] for x in t) and ap and all('once' in x['detail'] and 'deny' in x['detail'] for x in ap)))" && [ $rc -eq 0 ] && ok "contract-check --acceptance: 54 PASS, tool.started once deny, code 0" || ko "contract-check --acceptance (rc=$rc)"
# c. /_hv/config et /_hv/reset
python3 -I - "$HV_PORT" <<'PY' && ok "fake: /_hv/config et /_hv/reset réinitialisent l'état" || ko "fake: config/reset"
import json, sys, urllib.request, urllib.error
port = sys.argv[1]
base = "http://127.0.0.1:%s" % port
def req(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(base + path, data=data), timeout=5) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())
assert req("/_hv/config", [])[0] == 400
assert req("/_hv/config", {"mode": "invalid"})[0] == 400
assert req("/_hv/config", {"mode": "down"})[0] == 200
assert req("/health")[0] == 503
st, cfg = req("/_hv/config")
assert cfg["mode"] == "down"
assert req("/_hv/reset", {})[0] == 200
st, cfg = req("/_hv/config")
assert cfg["mode"] == "normal"
assert req("/health")[0] == 200
PY
"$E" down fake >/dev/null
rm -rf "$T"; exit $fail
