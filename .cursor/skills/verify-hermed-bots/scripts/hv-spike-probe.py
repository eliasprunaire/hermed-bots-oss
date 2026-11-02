#!/usr/bin/env python3
"""Sonde HD-01 : rejoue les formes observées par le spike S1 à S7 (docs/spike/) contre Hermes orb. Modèle : aucun.
Usage : hv-spike-probe.py --url http://127.0.0.1:18642 --out results.json [--container hv-hermes-test | --no-docker]
La clé vient de HV_TEST_API_KEY et n'est jamais affichée ni écrite. Une sonde qui échoue ou plante n'arrête pas les autres.
Les sondes qui lisent ou coupent le conteneur (ps, hermes profile list, network disconnect) utilisent docker ; --no-docker les saute.
Codes : 0 tout PASS ; 10 au moins un FAIL ; 2 usage."""
import argparse, http.client, json, os, signal, subprocess, sys, time, urllib.parse, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--container", default=os.environ.get("HV_CONTAINER", "hv-hermes-test"))
ap.add_argument("--no-docker", action="store_true"); ap.add_argument("--timeout", type=float, default=30.0)
a = ap.parse_args()
KEY = os.environ.get("HV_TEST_API_KEY", "")
U = urllib.parse.urlparse(a.url)
ACTIVE = ["default", "cyber", "gaming", "ia", "perso", "recherches", "sport", "tiny", "wikilibriste"]
BOT = "/p/hv-bot-a"

class Miss(AssertionError): pass
def need(cond, msg):
    if not cond: raise Miss(msg)

def conn(timeout=None): return http.client.HTTPConnection(U.hostname, U.port, timeout=timeout or a.timeout)

def req(method, path, body=None, headers=None, key=True):
    h = {"Content-Type": "application/json"}
    if key and KEY: h["Authorization"] = "Bearer " + KEY
    h.update(headers or {})
    c = conn()
    try:
        c.request(method, path, json.dumps(body) if body is not None else None, h)
        r = c.getresponse(); raw = r.read().decode("utf-8", "replace")
        try: j = json.loads(raw)
        except ValueError: j = None
        return r.status, dict(r.getheaders()), j
    finally: c.close()

def events(path, until, headers=None, max_s=45.0):
    """Lit le flux SSE jusqu'à un événement de `until` ; le serveur ne ferme pas la connexion (S1)."""
    h = {"Authorization": "Bearer " + KEY}; h.update(headers or {})
    c = conn(max_s); out = []; t0 = time.time(); status = None
    try:
        c.request("GET", path, headers=h); r = c.getresponse(); status = r.status
        ident = None
        try:
            while status == 200 and time.time() - t0 < max_s:
                raw = r.readline()
                if not raw: break
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line.startswith("id:"): ident = int(line[3:])
                elif line.startswith("data:"):
                    d = json.loads(line[5:]); d["_id"] = ident; d["_t"] = time.time() - t0; out.append(d)
                    if d.get("event") in until: break
        except TimeoutError: pass  # délai de lecture : fin voulue pour until vide
    finally: c.close()
    return status, out

def start(text, key=None, **extra):
    hd = {"Idempotency-Key": key} if key else None
    return req("POST", BOT + "/v1/runs", dict(input=text, **extra), hd)

def docker(*argv, timeout=20):  # groupe de processus séparé : le délai tue toute la descendance
    p = subprocess.Popen(["docker", *argv], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try: out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL); p.communicate(); raise
    return p.returncode, out

def ps():
    rc, out = docker("exec", a.container, "ps", "-eo", "pid,ppid,etime,args")
    need(rc == 0, "docker exec ps a rendu %d : %s" % (rc, out.strip()[:120]))
    return out
TERMINAL = {"run.completed", "run.failed", "run.cancelled", "run.interrupted"}
results = []
def probe(name, fn, needs_docker=False):
    t = time.time()
    if needs_docker and a.no_docker:
        results.append({"contract": name, "result": "FAIL", "detail": "sautée (--no-docker)", "ms": 0}); return
    try: detail = fn(); res = "PASS"
    except Miss as e: detail, res = "attendu: %s" % e, "FAIL"
    except Exception as e: detail, res = "crash: %r" % e, "FAIL"
    results.append({"contract": name, "result": res, "detail": detail, "ms": int((time.time() - t) * 1000)})

def s1_run():  # S1 : send_message + run_events
    st, _, j = start("bonjour hv")
    need(st == 202 and j and j.get("status") == "started" and j.get("replayed") is False and str(j.get("run_id", "")).startswith("run_"), "202 started %s %s" % (st, j))
    rid = j["run_id"]; st, ev = events("%s/v1/runs/%s/events" % (BOT, rid), TERMINAL)
    names = [e.get("event") for e in ev]
    need(st == 200 and names and names[0] == "message.delta" and names[-1] == "run.completed", "séquence %s %s" % (st, names))
    need([e["_id"] for e in ev] == [e.get("seq") for e in ev] == list(range(len(ev))), "id = seq depuis 0")
    need(ev[0]["_t"] < 5.0, "premier événement en %.2f s" % ev[0]["_t"])
    st, _, g = req("GET", "%s/v1/runs/%s" % (BOT, rid))
    need(st == 200 and g and g.get("status") == "completed" and g.get("completed") is True and g.get("session_id") == rid, "état %s" % g)
    return "events=%s premier=%d ms" % (names, ev[0]["_t"] * 1000)

def s1_failed():
    st, _, j = start("HV_FAIL go"); need(st == 202, "202")
    st, ev = events("%s/v1/runs/%s/events" % (BOT, j["run_id"]), TERMINAL)
    need(ev and ev[-1].get("event") == "run.failed", "run.failed %s" % [e.get("event") for e in ev])
    st, _, g = req("GET", "%s/v1/runs/%s" % (BOT, j["run_id"]))
    need(g and g.get("status") == "failed" and "HTTP 400" in str(g.get("error")), "état %s" % g)
    return "run.failed, %s" % g["error"]

def s2_resume():  # S2 : Idempotency-Key + Last-Event-ID, tour HV_SLOW (environ 20 s)
    k = "hv-probe-" + uuid.uuid4().hex
    st, _, j = start("HV_SLOW go", k); need(st == 202 and j and j.get("replayed") is False, "premier envoi %s" % st)
    rid = j["run_id"]; _, first = events("%s/v1/runs/%s/events" % (BOT, rid), set(), max_s=2.5)
    last = first[-1]["_id"] if first else 0; need(first, "aucun événement avant la coupure")
    st, h, j2 = start("HV_SLOW go", k)
    need(st == 202 and j2 and j2.get("run_id") == rid and j2.get("replayed") is True and h.get("Idempotency-Replayed") == "true", "même clé %s %s" % (st, j2))
    st2, _, c = start("autre corps", k)
    need(st2 == 409 and "idempotency_key_conflict" in json.dumps(c), "conflit %s %s" % (st2, c))
    st, rest = events("%s/v1/runs/%s/events" % (BOT, rid), TERMINAL, {"Last-Event-ID": str(last)})
    need(st == 200 and rest and rest[0]["_id"] == last + 1 and rest[-1].get("event") == "run.completed", "reprise après id %d : %s" % (last, [e["_id"] for e in rest][:3]))
    _, _, m = req("GET", "%s/api/sessions/%s/messages" % (BOT, rid))
    roles = [x.get("role") for x in (m or {}).get("data", [])]
    need(roles == ["user", "assistant"], "transcript %s" % roles)
    _, _, d1 = start("sans clé"); _, _, d2 = start("sans clé")
    need(d1 and d2 and d1["run_id"] != d2["run_id"], "sans clé : deux runs distincts")
    return "reprise après id %d, un seul tour, transcript %s" % (last, roles)

def s2_cut():  # S2 : coupure réseau réelle (docker network disconnect bridge) pendant un tour HV_SLOW, puis reprise par Last-Event-ID
    k = "hv-cut-" + uuid.uuid4().hex
    st, _, j = start("HV_SLOW go", k); need(st == 202 and j and j.get("replayed") is False, "envoi %s" % st)
    rid = j["run_id"]; _, first = events("%s/v1/runs/%s/events" % (BOT, rid), set(), max_s=2.5)
    need(first, "aucun événement avant la coupure"); last = first[-1]["_id"]
    rc, out = docker("network", "disconnect", "bridge", a.container); need(rc == 0, "disconnect a rendu %d : %s" % (rc, out.strip()[:120]))
    try:
        time.sleep(6)
        try: c = conn(2); c.request("GET", "/health"); c.getresponse(); refused = False
        except OSError: refused = True
        finally: c.close()
    finally:  # la reconnexion a toujours lieu, même si la mesure plante
        rc2, out2 = docker("network", "connect", "bridge", a.container)
    need(rc2 == 0, "connect a rendu %d : %s" % (rc2, out2.strip()[:120]))
    need(refused, "nouvelle connexion acceptée pendant la coupure")
    for _ in range(20):  # le port publié peut refuser quelques instants après la reconnexion
        try:
            if req("GET", "/health")[0] == 200: break
        except OSError: pass
        time.sleep(0.5)
    else: need(False, "/health ne répond pas 10 s après la reconnexion")
    st, rest = events("%s/v1/runs/%s/events" % (BOT, rid), TERMINAL, {"Last-Event-ID": str(last)})
    need(st == 200 and rest and rest[0]["_id"] == last + 1 and rest[-1].get("event") == "run.completed", "reprise après id %d : %s" % (last, [e["_id"] for e in rest][:3]))
    _, _, m = req("GET", "%s/api/sessions/%s/messages" % (BOT, rid)); roles = [x.get("role") for x in (m or {}).get("data", [])]
    st, h, j2 = start("HV_SLOW go", k)
    need(roles == ["user", "assistant"] and j2 and j2.get("run_id") == rid and j2.get("replayed") is True, "transcript %s, rejeu %s" % (roles, j2))
    return "coupure 6 s, connexion refusée pendant la coupure, reprise après id %d, un seul tour, transcript %s" % (last, roles)

def s3_cancel():  # S3 : cancel_run pendant un outil au premier plan
    st, _, j = start("HV_TOOL_SLEEP go"); need(st == 202, "202"); rid = j["run_id"]
    _, ev = events("%s/v1/runs/%s/events" % (BOT, rid), {"tool.started"}); need(ev and ev[-1].get("event") == "tool.started", "tool.started")
    for _ in range(25):  # tool.started précède le processus de quelques centaines de ms
        if "sleep 300" in ps(): break
        time.sleep(0.2)
    else: need(False, "sleep 300 absent avant le stop")
    t = time.time(); st, _, s = req("POST", "%s/v1/runs/%s/stop" % (BOT, rid))
    need(st == 200 and s and s.get("status") == "stopping", "stop %s %s" % (st, s))
    _, ev = events("%s/v1/runs/%s/events" % (BOT, rid), TERMINAL, max_s=15)
    need(ev and ev[-1].get("event") == "run.cancelled", "terminal %s" % [e.get("event") for e in ev])
    _, _, g = req("GET", "%s/v1/runs/%s" % (BOT, rid))
    need(g and g.get("status") == "cancelled" and g.get("interrupted") is True and g.get("completed") is False, "état %s" % g)
    time.sleep(1); need("sleep 300" not in ps(), "sleep 300 encore présent après le stop")
    return "cancelled en %.1f s, processus de l'outil retiré" % (time.time() - t)

def s4_model_new():  # S4 : new_session + set_model (verrou de session)
    st, _, n = req("POST", BOT + "/api/sessions", {})
    need(st == 201 and n and n.get("session", {}).get("message_count") == 0 and n["session"].get("model") is None, "création %s %s" % (st, n))
    sid = n["session"]["id"]; _, _, o = req("POST", BOT + "/api/sessions", {}); oid = o["session"]["id"]
    _, _, m = req("GET", "%s/api/sessions/%s/messages" % (BOT, sid)); need(m and m.get("data") == [], "session vide")
    st, _, lk = req("POST", "%s/api/sessions/%s/model" % (BOT, sid), {"model": "hv-fake-2"})
    need(st == 200 and lk and lk.get("object") == "hermes.session.model_lock" and lk["runtime"].get("model_lock") == "accepted", "verrou %s %s" % (st, lk))
    def reply(i): return str(((req("POST", "%s/api/sessions/%s/chat" % (BOT, i), {"input": "hello"})[2] or {}).get("message") or {}).get("content"))
    r1, r2 = reply(sid), reply(oid)
    need("model=hv-fake-2" in r1 and "model=hv-fake-1" in r2, "modèles %r / %r" % (r1, r2))
    st, _, j = start("sans effet", session_id=sid); _, ev = events("%s/v1/runs/%s/events" % (BOT, j["run_id"]), TERMINAL)
    need("model=hv-fake-1" in json.dumps(ev[-1]), "POST /v1/runs ignore le verrou")
    return "verrou tenu sur la session seule ; /v1/runs l'ignore"

def s5_sessions():  # S5 : list_sessions + réouverture
    st, _, l = req("GET", BOT + "/api/sessions?limit=3&offset=0")
    need(st == 200 and l and l.get("object") == "list" and l.get("limit") == 3 and "has_more" in l and 0 < len(l["data"]) <= 3, "liste %s" % st)
    e = l["data"][0]; miss = [k for k in ("id", "source", "model", "title", "message_count", "last_active", "preview") if k not in e]
    need(not miss, "champs manquants %s" % miss)
    la = [x["last_active"] for x in l["data"]]; need(la == sorted(la, reverse=True), "ordre par activité décroissante")
    sid = next((x["id"] for x in l["data"] if x["message_count"] >= 2), None); need(sid, "aucune session avec 2 messages")
    st, _, d = req("GET", "%s/api/sessions/%s" % (BOT, sid)); need(st == 200 and d.get("object") == "hermes.session", "détail %s" % st)
    _, _, m = req("GET", "%s/api/sessions/%s/messages" % (BOT, sid))
    need(m and m.get("object") == "list" and m.get("pagination", {}).get("limit") == 500 and m["data"][0].get("role") == "user", "transcript")
    _, _, other = req("GET", "/p/hv-bot-b/api/sessions?limit=50")
    need(sid not in [x["id"] for x in (other or {}).get("data", [])], "session de hv-bot-a visible depuis hv-bot-b")
    return "%d sessions, réouverture de %s, isolée de hv-bot-b" % (len(l["data"]), sid)

def s6_profiles():  # S6 : list_profiles (aucune route HTTP ; source = CLI)
    codes = [req("GET", p)[0] for p in ("/api/profiles", "/v1/profiles", "/profiles", "/api/profile", "/p/", "/p")]
    need(codes == [404] * 6, "routes de liste %s" % codes)
    rc, out = docker("exec", "-u", "hermes", "-e", "HOME=/opt/data", a.container, "hermes", "profile", "list")
    rows = {l.replace("◆", " ").split()[0]: l for l in out.splitlines() if "hv-fake-1" in l}
    need(rc == 0 and all(p in rows for p in ACTIVE + ["hv-old"]), "profils vus %s" % sorted(rows))
    need("stopped" in rows["hv-old"] and all("running" in rows[p] for p in ACTIVE), "état de hv-old / actifs")
    return "%d profils listés, hv-old stopped, neuf actifs running" % len(rows)

def s7_multiplex():  # S7 : routage /p/<profil>/ sur un seul port
    bad = []
    for p in ACTIVE:
        st, _, m = req("GET", "/p/%s/v1/models" % p); mid = ((m or {}).get("data") or [{}])[0].get("id")
        if st != 200 or mid != ("hermes-agent" if p == "default" else p): bad.append((p, st, mid))
    need(not bad, "profils en écart %s" % bad)
    for p in ("hv-old", "nope"):
        st, _, j = req("GET", "/p/%s/v1/models" % p); need(st == 404 and "Unknown or unconfigured profile" in json.dumps(j), "%s => %s" % (p, st))
    need(req("GET", "/p/cyber/v1/models", key=False)[0] == 401, "sans clé => 401")
    st, _, j = start("x"); rid = j["run_id"]
    need(req("GET", "/p/hv-bot-b/v1/runs/" + rid)[0] == 404 and req("GET", "%s/v1/runs/%s" % (BOT, rid))[0] == 200, "run isolé par profil")
    return "neuf profils actifs 200, hv-old et nope 404, run isolé"

probe("S1:send_message+run_events", s1_run); probe("S1:run.failed", s1_failed)
probe("S2:replay", s2_resume); probe("S2:network_cut", s2_cut, True); probe("S3:cancel_run", s3_cancel, True); probe("S4:set_model+new_session", s4_model_new)
probe("S5:list_sessions", s5_sessions); probe("S6:list_profiles", s6_profiles, True); probe("S7:multiplexing", s7_multiplex)

json.dump(results, open(a.out, "w"), ensure_ascii=False, indent=2)
for r in results: print("%-26s %s  %s" % (r["contract"], r["result"], r["detail"]))
sys.exit(10 if any(r["result"] == "FAIL" for r in results) else 0)
