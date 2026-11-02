#!/usr/bin/env python3
"""Vérifie chaque contrat de la fixture contre une instance Hermes (orb ou fake). Modèle : aucun.
Usage : hv-contract-check.py --url http://127.0.0.1:${HV_PORT} --fixture ../fixtures/hermes-current/contract.json --out results.json [--acceptance]
Chaque sonde est isolée : une sonde qui plante est notée FAIL (crash) et les autres continuent.
Un contrat compare le statut et les noms de champs de la réponse, jamais les valeurs. Un champ requis absent donne FAIL.
Un champ de `optional_fields` absent donne PASS (« default »). Un champ en plus donne PASS et figure dans `extra` (A7).
Une liste JSON doit être une liste et chacun de ses éléments est comparé à l'élément de référence (`data: null`, une chaîne ou un élément sans `id` donnent FAIL).
`send_message` envoie `repeat` messages dans la session verrouillée par `set_model` (décision S4) et compare les valeurs de `expect`, puis de `expect_locked` si `set_model` a réussi.
`list_profiles` lit `hermes profile list` par le canal `--profile-cmd` (décision S6), exclut les profils au Gateway `stopped` et vérifie chaque profil sur le port API.
Les contrats approve et cancel_run lancent d'abord un tour (`setup`), puis agissent sur lui.
Sondes de bord : celles de `edges` dans la fixture, avec le statut observé sur le vrai Hermes.
Codes : 0 tout PASS ; 10 au moins un FAIL ; 2 usage.
--acceptance : les six actions (liste, session, modèle, conversation, approbation, outil) sur les neuf profils du PRD ; même sémantique et mêmes codes."""
import argparse, http.client, json, os, shlex, signal, subprocess, sys, time, urllib.parse

ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True); ap.add_argument("--fixture", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--timeout", type=float, default=5.0)
ap.add_argument("--acceptance", action="store_true", help="six actions sur les neuf profils du PRD (daily)")
ap.add_argument("--profile-cmd", help="préfixe du canal de commande en lecture seule (ex. docker exec dans ${HV_CONTAINER}) ; absent : le faux serveur sert la liste sur /_hv/profile-list")
a = ap.parse_args()
C = json.load(open(a.fixture, encoding="utf-8"))
KEY = os.environ.get("HV_TEST_API_KEY", "")
U = urllib.parse.urlparse(a.url)
OPT = set(C.get("optional_fields") or [])
TERMINAL = {"run.completed", "run.failed", "run.cancelled", "run.interrupted"}
UNKNOWN = "hv.unknown_future_event"
EVENTS = {e["event"]: e for e in C["events"]}
CTX = {"profile": "hv-bot-a", "session": "api_unknown", "run": "run_unknown"}  # session et run : remplacés par les contrats qui les créent
LOCKED = []  # rempli quand set_model réussit : send_message vérifie alors le verrou

def fill(path, **over):
    for k, v in dict(CTX, **over).items(): path = path.replace("{" + k + "}", v)
    return path

def headers(auth=True, extra=None):
    h = {"Content-Type": "application/json"}
    if auth and KEY: h["Authorization"] = "Bearer " + KEY
    h.update(extra or {})
    return h

def req(method, path, body=None, auth=True, raw=None):
    data = raw.encode() if raw is not None else (json.dumps(body).encode() if body is not None else None)
    c = http.client.HTTPConnection(U.hostname, U.port, timeout=a.timeout)
    try:
        c.request(method, path, data, headers(auth)); r = c.getresponse()
        return r.status, r.read().decode("utf-8", "replace")
    finally: c.close()

def stream(path, wait):
    """Lit le flux SSE ligne à ligne jusqu'à l'événement `wait` ou un événement terminal.
    Hermes ne ferme pas la connexion après `: stream closed`, donc une lecture jusqu'à la fin du fichier bloquerait."""
    c = http.client.HTTPConnection(U.hostname, U.port, timeout=a.timeout); events, ids, ident = [], [], None
    try:
        c.request("GET", path, headers=headers()); r = c.getresponse()
        if r.status != 200: return r.status, events, ids
        deadline = time.time() + a.timeout
        while time.time() < deadline:
            raw = r.readline()
            if not raw: break
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if line.startswith("id:"): ident = int(line[3:])
            elif line.startswith("data:"):
                ev = json.loads(line[5:]); events.append(ev); ids.append(ident)
                if ev.get("event") in TERMINAL or (wait and ev.get("event") == wait): break
        return r.status, events, ids
    finally: c.close()

def shape(ref, got, path=""):
    """Compare les noms de champs : (requis absents, facultatifs absents, en plus). Une liste attendue doit être une liste, chaque élément suit l'élément de référence"""
    miss, opt, extra = [], [], []
    if isinstance(ref, dict):
        if not isinstance(got, dict): return [path + k for k in ref], opt, extra
        for k in ref:
            if k not in got: (opt if k in OPT else miss).append(path + k)
            else:
                m, o, e = shape(ref[k], got[k], path + k + "."); miss += m; opt += o; extra += e
        extra += [path + k for k in got if k not in ref]
    elif isinstance(ref, list) and ref:
        if not isinstance(got, list): return [path.rstrip(".") + " (liste attendue)"], opt, extra
        for item in got:
            m, o, e = shape(ref[0], item, path.rstrip(".") + "[]."); miss += m; opt += o; extra += e
        miss, opt, extra = (list(dict.fromkeys(x)) for x in (miss, opt, extra))
    return miss, opt, extra

def dig(obj, dotted):
    for k in dotted.split("."):
        obj = obj.get(k) if isinstance(obj, dict) else None
    return obj

def profile_table(text, c):
    """Lit la table de `hermes profile list` : (actifs, arrêtés). Les lignes d'en-tête et de séparation n'ont pas de nom de profil"""
    active, stopped, col = [], [], 2
    for line in text.splitlines():
        t = line.replace("\u25c6", " ").split()
        if not t or not any(ch.isalnum() for ch in line): continue
        if t[0] == "Profile":
            col = t.index("Gateway"); continue
        (stopped if len(t) > col and t[col] == c["stopped_gateway"] else active).append(t[0])
    return active, stopped

def run_readonly(argv):
    """Lance la commande dans un groupe de processus séparé, tué en entier au délai (rule subprocess-timeouts)"""
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, text=True)
    try: out, _ = p.communicate(timeout=a.timeout * 4)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL); p.communicate(); raise
    return p.returncode, out

def list_profiles(c):
    if not (c.get("read_only") and c["command"][:3] == ["hermes", "profile", "list"] and len(c["command"]) == 3): return False, "commande hors liste blanche en lecture seule : %s" % c["command"]
    if a.profile_cmd: rc, text = run_readonly(shlex.split(a.profile_cmd) + c["command"])
    else:
        st, text = req("GET", "/_hv/profile-list", auth=False); rc = 0 if st == 200 else st
    active, stopped = profile_table(text, c)
    want, gone = set(C["profiles"]["served"]), set(C["profiles"]["stopped"])
    bad = []
    if rc != c["exit"]: bad.append("code=%s" % rc)
    if set(active) != want: bad.append("actifs: en trop %s, manquants %s" % (sorted(set(active) - want), sorted(want - set(active))))
    if set(stopped) != gone: bad.append("arrêtés: en trop %s, manquants %s" % (sorted(set(stopped) - gone), sorted(gone - set(stopped))))
    for name, expect in [(n, 200) for n in active] + [(n, 404) for n in stopped]:
        st = req("GET", "/p/%s/v1/models" % name)[0]
        if st != expect: bad.append("%s: status=%s au lieu de %s" % (name, st, expect))
    return not bad, "actifs=%d arrêtés=%s %s" % (len(active), stopped, "; ".join(bad))

def event_gaps(events):
    gaps = []
    for ev in events:
        ref = EVENTS.get(ev.get("event"))
        if ref is None or ev.get("event") == UNKNOWN: continue  # événement hors fixture ou inconnu voulu : ignoré
        miss = shape(ref, ev)[0]
        if miss: gaps.append("%s: manque %s" % (ev["event"], miss))
    return gaps

def jload(text):
    try: return json.loads(text)
    except ValueError: return {}

def contract(name, c):
    over, waited = {}, None
    if c.get("transport") == "ssh": return list_profiles(c)
    if c["response"] == "SSE":
        st, events, ids = stream(fill(c["path"]), None)
        names = [e.get("event") for e in events]; gaps = event_gaps(events)
        ok = st == 200 and ids == [e.get("seq") for e in events] == list(range(len(events))) and names[-1:] == ["run.completed"] and not gaps
        return ok, "status=%s events=%s ids=seq=0..n %s" % (st, names, gaps or "")
    if "setup" in c:  # un tour en cours, puis l'événement attendu : approval.request ou tool.started
        send = C["contracts"]["start_run"]
        st, text = req("POST", fill(send["path"]), {"input": c["setup"]["input"]}); rid = jload(text).get("run_id")
        if st != send["status"] or not rid: return False, "status=%s (tour de préparation)" % st
        st, events, _ = stream(fill(C["contracts"]["run_events"]["path"], run=rid), c["setup"]["wait"])
        waited = next((e for e in events if e.get("event") == c["setup"]["wait"]), None)
        if not waited: return False, "status=%s événement %s absent : %s" % (st, c["setup"]["wait"], [e.get("event") for e in events])
        gaps = event_gaps(events)
        if gaps: return False, "status=%s événements : %s" % (st, gaps)
        over["run"] = rid
    body = c.get("body")
    if body is not None and waited is not None:  # "$nom" prend la valeur du champ `nom` de l'événement attendu
        body = {k: waited.get(v[1:]) if isinstance(v, str) and v.startswith("$") else v for k, v in body.items()}
    wrong = []
    for i in range(c.get("repeat", 1)):  # send_message : plusieurs messages dans la même session
        st, text = req(c["method"], fill(c["path"], **over), body, auth=c.get("auth", True))
        j = jload(text); miss, opt, extra = shape(c["response"], j)
        want = dict(c.get("expect", {}), **(c.get("expect_locked", {}) if LOCKED else {}))
        wrong += ["#%d %s=%r attendu %r" % (i + 1, k, dig(j, k), fill(v)) for k, v in want.items() if dig(j, k) != fill(v)]
        if st != c["status"] or miss: break
    if st == c["status"]:
        if name == "new_session": CTX["session"] = j.get("session", {}).get("id", CTX["session"])
        if name == "start_run": CTX["run"] = j.get("run_id", CTX["run"])
        if name == "set_model" and not miss: LOCKED.append(1)
    detail = "status=%s missing=%s default=%s extra=%s" % (st, miss, opt, extra)
    if wrong: detail += " valeurs=%s" % wrong
    if name == "version": detail = "version=%s %s" % (j.get("version"), detail)
    return st == c["status"] and not miss and not wrong, detail

results = []
def probe(name, fn):
    t = time.time()
    try:
        ok, detail = fn()
        results.append({"contract": name, "result": "PASS" if ok else "FAIL", "detail": detail, "ms": int((time.time()-t)*1000)})
    except Exception as e:  # sonde plantée = échec, on continue
        results.append({"contract": name, "result": "FAIL", "detail": "crash: %r" % e, "ms": int((time.time()-t)*1000)})

for name, c in C["contracts"].items():
    probe(name, lambda name=name, c=c: contract(name, c))

for e in C.get("edges", []):
    def edge(e=e):
        st = req(e["method"], fill(e["path"]), e.get("body"), auth=e.get("auth", True), raw=e.get("raw"))[0]
        return st == e["status"], "status=%s attendu=%s" % (st, e["status"])
    probe("edge:" + e["name"], edge)

if a.acceptance:
    prd = [p for p in C["profiles"]["served"] if not str(p).startswith("hv-")]
    def tool_contract():
        send = C["contracts"]["start_run"]
        st, text = req("POST", fill(send["path"]), {"input": C["contracts"]["cancel_run"]["setup"]["input"]})
        rid = jload(text).get("run_id")
        if st != send["status"] or not rid:
            return False, "status=%s (outil)" % st
        st, events, _ = stream(fill(C["contracts"]["run_events"]["path"], run=rid), "tool.started")
        names = [e.get("event") for e in events]
        ok = st == 200 and any(e.get("event") == "tool.started" for e in events)
        return ok, "status=%s events=%s tool.started" % (st, names)
    def approve_contract():
        parts = []
        for choice in ("once", "deny"):
            c = json.loads(json.dumps(C["contracts"]["approve"]))
            c["body"]["choice"] = choice
            c.setdefault("expect", {})["choice"] = choice
            ok, detail = contract("approve", c)
            parts.append("%s %s" % (choice, detail))
            if not ok:
                return False, " ".join(parts)
        return True, "once deny " + "; ".join(parts)
    actions = (
        ("profile_served", lambda: contract("profile_served", C["contracts"]["profile_served"])),
        ("new_session", lambda: contract("new_session", C["contracts"]["new_session"])),
        ("set_model", lambda: contract("set_model", C["contracts"]["set_model"])),
        ("send_message", lambda: contract("send_message", C["contracts"]["send_message"])),
        ("tool", tool_contract),
        ("approve", approve_contract),
    )
    for profile in prd:
        CTX["profile"] = profile
        CTX["session"] = "api_unknown"
        CTX["run"] = "run_unknown"
        LOCKED.clear()
        for name, fn in actions:
            probe("acceptance:%s:%s" % (profile, name), fn)

json.dump(results, open(a.out, "w"), ensure_ascii=False, indent=2)
for r in results: print("%-22s %s  %s" % (r["contract"], r["result"], r["detail"]))
sys.exit(10 if any(r["result"] == "FAIL" for r in results) else 0)
