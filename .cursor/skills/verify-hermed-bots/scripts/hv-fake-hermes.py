#!/usr/bin/env python3
"""Faux serveur Hermes piloté par fixtures (A10). Modèle : aucun (script).
Écoute uniquement sur 127.0.0.1. Sert les routes, statuts et champs relevés par le spike (fixtures/README.md).
Usage : hv-fake-hermes.py --port ${HV_PORT} --version current --mode normal --fixtures ../fixtures
Routes de contrôle (test uniquement, hors contrat) :
  GET /_hv/ready ; POST /_hv/inject {"event":...} ajoute un événement au flux ;
  POST /_hv/cut {"seconds":N} simule une coupure réseau (503 sur les routes de contrat) ;
  GET /_hv/log journal des requêtes reçues (preuve : pas de double envoi) ;
  GET /_hv/profile-list sortie de `hermes profile list` (stand-in du canal SSH en lecture seule, décision S6) ;
  POST /_hv/config {mode, drop, reject_key, omit_tokens, version, profiles} règle l'état (400 si corps ou mode invalide) ;
  POST /_hv/reset rétablit l'état initial (injections, journaux, tours, mode). GET /_hv/config lit l'état courant.
Mode malformed (HV_MALFORMED=null|string|noid|leak|nolock) : contrôles négatifs du validateur de conteneurs et de la liste des profils.
Exige l'en-tête Authorization: Bearer <HV_TEST_API_KEY> si la variable est définie, sauf sur un contrat `auth: false`.
Différence voulue avec Hermes : le flux d'événements est fermé après `: stream closed`."""
import argparse, json, os, re, sys, time, threading, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=int(os.environ.get("HV_PORT", "18642")))
ap.add_argument("--version", default="current")
ap.add_argument("--mode", default="normal", choices=["normal", "slow", "down", "drop-route", "fields", "malformed"])
ap.add_argument("--fixtures", default=os.path.join(os.path.dirname(__file__), "..", "fixtures"))
a = ap.parse_args()
C = json.load(open(os.path.join(a.fixtures, "hermes-" + a.version, "contract.json"), encoding="utf-8"))
DROP = os.environ.get("HV_DROP", "set_model")
KEY = os.environ.get("HV_TEST_API_KEY")
LOG, INJ, LOCK = [], [], threading.Lock()
CUT_UNTIL = [0.0]
RUNS = set()
MODEL, MSGS = {}, {}  # verrou de modèle et nombre de messages par session
MALFORMED = os.environ.get("HV_MALFORMED", "null")
SESSIONS = {s["id"] for s in C["contracts"]["list_sessions"]["response"]["data"]}
MODES = {"normal", "slow", "down", "drop-route", "fields", "malformed"}
SEED_SESSIONS = set(SESSIONS)
STATE = {
    "mode": a.mode,
    "drop": DROP,
    "reject_key": False,
    "omit_tokens": False,
    "version": C["version"],
    "profiles": None,
}

def apply_config(obj):
    if not isinstance(obj, dict):
        return 400
    if "mode" in obj and obj["mode"] not in MODES:
        return 400
    if "mode" in obj:
        STATE["mode"] = obj["mode"]
    if "drop" in obj:
        STATE["drop"] = obj["drop"]
    if "reject_key" in obj:
        STATE["reject_key"] = bool(obj["reject_key"])
    if "omit_tokens" in obj:
        STATE["omit_tokens"] = bool(obj["omit_tokens"])
    if "version" in obj and obj["version"] is not None:
        STATE["version"] = obj["version"]
    if "profiles" in obj:
        STATE["profiles"] = obj["profiles"]
    return 200

def reset_state():
    LOG.clear()
    INJ.clear()
    RUNS.clear()
    MODEL.clear()
    MSGS.clear()
    SESSIONS.clear()
    SESSIONS.update(SEED_SESSIONS)
    CUT_UNTIL[0] = 0.0
    STATE.update(mode=a.mode, drop=DROP, reject_key=False, omit_tokens=False, version=C["version"], profiles=None)

def compile_path(path):
    parts = re.split(r"\{(\w+)\}", path)  # le découpage alterne texte et nom de variable
    return re.compile("^" + "".join(re.escape(p) if i % 2 == 0 else "(?P<%s>[^/]+)" % p for i, p in enumerate(parts)) + "$")

ROUTES = [(name, c, compile_path(c["path"])) for name, c in C["contracts"].items() if "path" in c]  # list_profiles passe par SSH, pas par HTTP

def match(method, path):
    for name, c, rx in ROUTES:
        m = rx.match(path)
        if m and c["method"] == method:
            return name, c, m.groupdict()
    return None, None, {}

def fill(obj, v):
    if isinstance(obj, str):
        for k, x in v.items(): obj = obj.replace("{" + k + "}", x)
        return obj
    if isinstance(obj, dict): return {k: fill(x, v) for k, x in obj.items()}
    if isinstance(obj, list): return [fill(x, v) for x in obj]
    return obj

def mutate(obj):
    if isinstance(obj, dict):
        o = {k: mutate(x) for k, x in obj.items() if k != (C.get("optional_fields") or [None])[0]}
        o["zz_new_field"] = "ignore-moi"
        return o
    if isinstance(obj, list):
        return [mutate(x) for x in obj]
    return obj

def corrupt(obj):
    """Mode malformed : abîme chaque liste `data` (null, chaîne, ou second élément sans id)"""
    if isinstance(obj, dict):
        o = {k: corrupt(x) for k, x in obj.items()}
        if MALFORMED in ("null", "string", "noid") and isinstance(o.get("data"), list) and o["data"]:
            first = o["data"][0]
            o["data"] = {"null": None, "string": "x"}.get(MALFORMED, o["data"] + [{k: x for k, x in first.items() if k != "id"}])
        return o
    return obj

def err(code, message, type_="invalid_request_error"):
    return {"error": {"message": message, "type": type_, "param": None, "code": code}}

class H(BaseHTTPRequestHandler):
    def log_message(self, *x): pass
    def _send(self, code, body):
        b = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _send_text(self, code, text):
        b = text.encode()
        self.send_response(code); self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _stream(self, v):
        last = int(self.headers.get("Last-Event-ID") or -1)
        events = [fill(e, v) for e in C["events"]] + list(INJ)
        if STATE["omit_tokens"]:
            events = [{k: x for k, x in ev.items() if k != "usage"} if isinstance(ev, dict) else ev for ev in events]
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        try:
            self.wfile.write(b": open\n\n")
            for i, ev in enumerate(events):
                if i <= last: continue
                ev = dict(ev, seq=i, timestamp=time.time())
                self.wfile.write(("id: %d\ndata: %s\n\n" % (i, json.dumps(ev, ensure_ascii=False))).encode()); self.wfile.flush()
                time.sleep(0.05)
            self.wfile.write(b": stream closed\n\n"); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):  # le client s'arrête au premier événement terminal
            pass
    def _handle(self, method):
        path = self.path.split("?")[0]
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        with LOCK: LOG.append({"t": time.time(), "m": method, "p": path, "body": body})
        if path == "/_hv/ready": return self._send(200, {"ok": True, "version": STATE["version"], "mode": STATE["mode"]})
        if path == "/_hv/log": return self._send(200, LOG)
        if path == "/_hv/config":
            if method == "GET":
                return self._send(200, {k: STATE[k] for k in ("mode", "drop", "reject_key", "omit_tokens", "version", "profiles")})
            try:
                obj = json.loads(body or "{}")
            except ValueError:
                return self._send(400, err(None, "Invalid JSON"))
            code = apply_config(obj)
            return self._send(code, {"ok": True} if code == 200 else err(None, "Invalid config"))
        if path == "/_hv/reset":
            reset_state()
            return self._send(200, {"ok": True})
        if path == "/_hv/profile-list":
            out = C["contracts"]["list_profiles"]["output"]
            return self._send_text(200, out.replace("stopped", "running") if STATE["mode"] == "malformed" and MALFORMED == "leak" else out)
        if path == "/_hv/inject":
            INJ.append(json.loads(body or "{}")); return self._send(200, {"ok": True})
        if path == "/_hv/cut":
            CUT_UNTIL[0] = time.time() + float(json.loads(body or "{}").get("seconds", 5)); return self._send(200, {"ok": True})
        if time.time() < CUT_UNTIL[0] or STATE["mode"] == "down": return self._send(503, {"error": "unavailable"})
        name, c, v = match(method, path)
        if STATE["reject_key"] and not (c and c.get("auth") is False):
            return self._send(401, err("gateway_auth_failed", "Invalid gateway API key (API_SERVER_KEY)", "gateway_auth_error"))
        if not (c and c.get("auth") is False) and KEY and self.headers.get("Authorization") != "Bearer " + KEY:
            return self._send(401, err("gateway_auth_failed", "Invalid gateway API key (API_SERVER_KEY)", "gateway_auth_error"))
        if STATE["mode"] == "slow": time.sleep(8)
        if not c or (STATE["mode"] == "drop-route" and name == STATE["drop"]): return self._send(404, {"error": "404: Not Found"})
        served = STATE["profiles"] if STATE["profiles"] else C["profiles"]["served"]
        if "profile" in v and v["profile"] not in served: return self._send(404, {"error": "Unknown or unconfigured profile"})
        if "run" in v and v["run"] not in RUNS: return self._send(404, err("run_not_found", "Run not found: " + v["run"]))
        if "session" in v and v["session"] not in SESSIONS: return self._send(404, err("session_not_found", "Session not found: " + v["session"]))
        if method == "POST" and "body" in c:  # une clé de `body` absente ou vide donne 400, comme Hermes
            try: j = json.loads(body or "{}")
            except ValueError: return self._send(400, err(None, "Invalid JSON"))
            if not isinstance(j, dict) or [k for k in c["body"] if j.get(k) in (None, "")]: return self._send(400, err(None, "Missing field"))
        v = dict(v, new_run="run_" + uuid.uuid4().hex, new_session="api_%d_%s" % (time.time(), uuid.uuid4().hex[:8]))
        if name == "start_run": RUNS.add(v["new_run"])
        if name == "new_session": SESSIONS.add(v["new_session"])
        if name == "set_model" and not (STATE["mode"] == "malformed" and MALFORMED == "nolock"): MODEL[v["session"]] = json.loads(body)["model"]
        if name == "send_message":  # le chat de session lit le verrou de modèle (S4)
            MSGS[v["session"]] = MSGS.get(v["session"], 0) + 1
            v = dict(v, model=MODEL.get(v["session"], "hv-fake-1"), route_source="session_model_lock" if v["session"] in MODEL else "global", n=str(MSGS[v["session"]]))
        if c["response"] == "SSE": return self._stream(v)
        resp = fill(c["response"], v)
        if name == "version":
            resp = dict(resp, version=STATE["version"])
        self._send(c.get("status", 200), mutate(resp) if STATE["mode"] == "fields" else corrupt(resp) if STATE["mode"] == "malformed" else resp)
    def do_GET(self): self._handle("GET")
    def do_POST(self): self._handle("POST")

srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
print("fake-hermes", C["version"], a.mode, a.port, flush=True)
srv.serve_forever()
