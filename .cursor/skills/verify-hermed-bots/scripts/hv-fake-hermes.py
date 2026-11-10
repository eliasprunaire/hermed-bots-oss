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
Exige l'en-tête Authorization: Bearer de la clé du profil dans HV_TEST_API_KEYS (JSON objet), ou HV_TEST_API_KEY si cette carte est absente, sauf sur un contrat `auth: false` sans profil.
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
def load_keys():
    raw = os.environ.get("HV_TEST_API_KEYS")
    if raw is None or raw == "":
        return None
    try:
        obj = json.loads(raw)
    except ValueError:
        return {}
    return obj if isinstance(obj, dict) else {}
KEYS = load_keys()
KEY = os.environ.get("HV_TEST_API_KEY")
LOG, INJ, LOCK = [], [], threading.Lock()

def log_sse(ev):
    """Heure d'émission SSE : la sonde HD-09 lit /_hv/sse/message.delta sous le texte du delta."""
    name = ev.get("event")
    entry = None
    if name == "approval.request":
        entry = {"t": time.time(), "m": "SSE", "p": "/_hv/sse/approval.request"}
    elif name == "message.delta":
        entry = {"t": time.time(), "m": "SSE", "p": "/_hv/sse/message.delta", "body": ev.get("delta") or ""}
    if entry is None:
        return
    with LOCK:
        LOG.append(entry)

CUT_UNTIL = [0.0]
RUNS = set()
MODEL, MSGS = {}, {}  # verrou de modèle et nombre de messages par session
PROFILE_MODELS = {}  # modèles posés par POST /_hv/profile-models (reset les efface)
SESSION_MSGS = {}  # (profile, session) -> messages ; seed = fixtures, nouvelle session = []
RUN_INPUT = {}  # run_id -> {input, session, profile}
PENDING = {}  # run_id -> {gate, choice, request_id} pour HV_APPROVAL
RECORDED_RUNS = set()  # run_id déjà versés au transcript (dédup par id, pas par texte)
RUN_SSE = {}  # run_id -> {events, choice, request_id} pour reprise Last-Event-ID
MALFORMED = os.environ.get("HV_MALFORMED", "null")
SEED_SESSIONS = {s["id"] for s in C["contracts"]["list_sessions"]["response"]["data"]}
SESSIONS = {}  # profile -> set(session_id)
MODES = {"normal", "slow", "down", "drop-route", "fields", "malformed"}
SEED_MSG_DATA = [
    {"id": 13, "session_id": "{session}", "role": "user", "content": "Bonjour", "tool_call_id": None, "tool_calls": None, "tool_name": None, "timestamp": 1792330255.35, "token_count": None, "finish_reason": None, "reasoning": None, "reasoning_content": None, "display_kind": None},
    {"id": 14, "session_id": "{session}", "role": "assistant", "content": "Réponse de test", "tool_call_id": None, "tool_calls": None, "tool_name": None, "timestamp": 1792330255.68, "token_count": None, "finish_reason": "stop", "reasoning": None, "reasoning_content": None, "display_kind": None},
]
STATE = {
    "mode": a.mode,
    "drop": DROP,
    "reject_key": False,
    "omit_tokens": False,
    "version": C["version"],
    "profiles": None,
}

def _seed_profiles():
    if STATE["profiles"] is not None:
        return list(STATE["profiles"])
    return list(C["profiles"]["served"])

def seed_session_messages():
    SESSION_MSGS.clear()
    SESSIONS.clear()
    RECORDED_RUNS.clear()
    RUN_SSE.clear()
    PENDING.clear()
    for profile in _seed_profiles():
        SESSIONS[profile] = set(SEED_SESSIONS)
        for sid in SEED_SESSIONS:
            SESSION_MSGS[(profile, sid)] = [dict(m, session_id=sid) for m in SEED_MSG_DATA]

seed_session_messages()

def _msg(session_id, role, content, mid):
    return {
        "id": mid,
        "session_id": session_id,
        "role": role,
        "content": content,
        "tool_call_id": None,
        "tool_calls": None,
        "tool_name": None,
        "timestamp": time.time(),
        "token_count": None,
        "finish_reason": ("stop" if role == "assistant" else None),
        "reasoning": None,
        "reasoning_content": None,
        "display_kind": None,
    }

def record_run_transcript(run_id, assistant_text):
    """Après un tour : aligne session_messages sur le flux pour que reread ne vide pas l'écran."""
    meta = RUN_INPUT.get(run_id)
    if not isinstance(meta, dict):
        return
    sid = meta.get("session")
    profile = meta.get("profile")
    user_txt = meta.get("input") or ""
    if not sid or not profile:
        return
    # Déduplique par identifiant de run (deux tours à même texte restent distincts).
    if run_id in RECORDED_RUNS:
        return
    RECORDED_RUNS.add(run_id)
    bucket = SESSION_MSGS.setdefault((profile, sid), [])
    base = 1000 + len(bucket)
    if user_txt:
        bucket.append(_msg(sid, "user", user_txt, base))
        base += 1
    if assistant_text:
        bucket.append(_msg(sid, "assistant", assistant_text, base))

def session_row(sid, profile=None):
    if profile is not None:
        msgs = SESSION_MSGS.get((profile, sid)) or []
    else:
        # repli : première occurrence (listes hors profil)
        msgs = []
        for (p, s), bucket in SESSION_MSGS.items():
            if s == sid:
                msgs = bucket
                break
    preview = ""
    for m in msgs:
        if m.get("role") == "user" and m.get("content"):
            preview = str(m["content"])[:80]
            break
    return {
        "id": sid,
        "source": "api_server",
        "user_id": None,
        "model": MODEL.get((profile, sid)) if profile is not None else MODEL.get(sid),
        "title": None,
        "started_at": time.time(),
        "ended_at": None,
        "end_reason": None,
        "message_count": len(msgs),
        "tool_call_count": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_tokens": 0,
        "cache_write_tokens": 0,
        "reasoning_tokens": 0,
        "estimated_cost_usd": None,
        "actual_cost_usd": None,
        "api_call_count": 0,
        "parent_session_id": None,
        "last_active": time.time(),
        "preview": preview or sid,
        "pinned": False,
        "archived": False,
        "hidden": False,
        "has_system_prompt": False,
        "has_model_config": sid in MODEL,
        "is_internal_child": False,
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
        STATE["profiles"] = obj["profiles"] if obj["profiles"] is not None else None
    return 200

def reset_state():
    LOG.clear()
    INJ.clear()
    RUNS.clear()
    MODEL.clear()
    MSGS.clear()
    PROFILE_MODELS.clear()
    RUN_INPUT.clear()
    PENDING.clear()
    RECORDED_RUNS.clear()
    RUN_SSE.clear()
    CUT_UNTIL[0] = 0.0
    STATE.update(mode=a.mode, drop=DROP, reject_key=False, omit_tokens=False, version=C["version"], profiles=None)
    seed_session_messages()

def compile_path(path):
    parts = re.split(r"\{(\w+)\}", path)  # le découpage alterne texte et nom de variable
    return re.compile("^" + "".join(re.escape(p) if i % 2 == 0 else "(?P<%s>[^/]+)" % p for i, p in enumerate(parts)) + "$")

MSG = {
    "method": "GET",
    "path": "/p/{profile}/api/sessions/{session}/messages",
    "status": 200,
    "response": {
        "object": "list",
        "session_id": "{session}",
        "data": [],  # remplacé à la volée depuis SESSION_MSGS
    },
}
VERSION_P = dict(C["contracts"]["version"], path="/p/{profile}/health")
VERSION_P.pop("auth", None)
ROUTES = [(name, c, compile_path(c["path"])) for name, c in C["contracts"].items() if "path" in c]
ROUTES.append(("version", VERSION_P, compile_path(VERSION_P["path"])))
ROUTES.append(("session_messages", MSG, compile_path(MSG["path"])))

def served_profiles():
    if STATE["profiles"] is not None:
        return STATE["profiles"]
    return C["profiles"]["served"]

def _profile_row(name, model, gateway, diamond=False):
    mark = "\u25c6" if diamond else " "
    return " %s%-15s %-28s %-12s %-12s %s\n" % (mark, name, model, gateway, "\u2014", "\u2014")

def profile_list_text():
    # Construit la table depuis la configuration (profils ajoutés et noms longs inclus).
    out = C["contracts"]["list_profiles"]["output"]
    if STATE["mode"] == "malformed" and MALFORMED == "leak":
        out = out.replace("stopped", "running")
    header, seed_rows, order = [], {}, []
    stopped = set(C["profiles"].get("stopped") or [])
    for line in out.splitlines(True):
        t = line.replace("\u25c6", " ").split()
        if not seed_rows and (not t or t[0] == "Profile" or not any(ch.isalnum() for ch in line)):
            header.append(line)
            continue
        if not t:
            continue
        name = t[0]
        if name not in seed_rows:
            order.append(name)
        seed_rows[name] = line
    if STATE["profiles"] is None:
        names = order
    else:
        names = list(STATE["profiles"])
    lines = list(header)
    for i, name in enumerate(names):
        model = PROFILE_MODELS.get(name)
        if name in seed_rows and model is None:
            lines.append(seed_rows[name])
            continue
        if name in seed_rows:
            parts = seed_rows[name].replace("\u25c6", " ").split()
            gateway = parts[2] if len(parts) > 2 else ("stopped" if name in stopped else "running")
            lines.append(_profile_row(name, model, gateway, diamond=("\u25c6" in seed_rows[name])))
            continue
        lines.append(_profile_row(name, model or "hv-fake-1", "running", diamond=(i == 0)))
    return "".join(lines)

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
    def _stamp_log(self, code):
        with LOCK:
            i = getattr(self, "_log_i", None)
            if i is None or i >= len(LOG):
                return
            if "s" not in LOG[i]:
                LOG[i]["s"] = code
                if self.headers.get("X-Hermed-Capability-Probe") == "1":
                    LOG[i]["probe"] = True
    def _send(self, code, body):
        self._stamp_log(code)
        b = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _send_text(self, code, text):
        self._stamp_log(code)
        b = text.encode()
        self.send_response(code); self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _emit_sse(self, events, pace):
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        try:
            self.wfile.write(b": open\n\n")
            last = int(self.headers.get("Last-Event-ID") or -1)
            for i, ev in enumerate(events):
                if i <= last:
                    continue
                ev = dict(ev, seq=i, timestamp=time.time())
                log_sse(ev)
                self.wfile.write(("id: %d\ndata: %s\n\n" % (i, json.dumps(ev, ensure_ascii=False))).encode()); self.wfile.flush()
                time.sleep(pace)
            self.wfile.write(b": stream closed\n\n"); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
    def _approval_events(self, run, inp):
        huge = "HV_APPROVAL_HUGE" in inp
        cmd = ("HUGE-BEGIN " + ("x" * 200000)) if huge else "/tmp/hv.txt"
        with LOCK:
            cached = RUN_SSE.get(run)
            if cached is not None:
                return list(cached["head"]), cached["request_id"], True
            req_id = "apr_" + (run or "x")
            PENDING[run] = {"gate": threading.Event(), "choice": None, "request_id": req_id}
            head = [
                {"event": "tool.started", "run_id": run, "tool": "file.write", "preview": cmd},
                {"event": "approval.request", "run_id": run, "request_id": req_id, "tool": "file.write",
                 "command": cmd, "description": "écrire le fichier", "choices": ["once", "session", "always", "deny"],
                 "allow_permanent": True, "allow_session": True},
            ]
            RUN_SSE[run] = {"head": list(head), "tail": None, "request_id": req_id, "choice": None}
            return head, req_id, False
    def _stream(self, v):
        self._stamp_log(200)
        run = v.get("run")
        meta = RUN_INPUT.get(run) if run else None
        if isinstance(meta, dict):
            inp = meta.get("input") or ""
        elif isinstance(meta, str):
            inp = meta
        else:
            inp = ""
        pace = 1.0 if "HV_SLOW" in inp else 0.05
        if STATE["omit_tokens"]:
            def strip_usage(ev):
                return {k: x for k, x in ev.items() if k != "usage"} if isinstance(ev, dict) else ev
        else:
            def strip_usage(ev):
                return ev
        if run and "HV_LOOP" in inp:
            preview = "ls /tmp"
            events = [
                {"event": "tool.started", "run_id": run, "tool": "terminal", "preview": preview},
                {"event": "tool.started", "run_id": run, "tool": "terminal", "preview": preview},
                {"event": "tool.started", "run_id": run, "tool": "terminal", "preview": preview},
                {"event": "run.completed", "run_id": run, "output": "HV-FAKE-TOOL-DONE", "completed": True,
                 "partial": False, "interrupted": False,
                 "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0},
                 "runtime": {"provider": "custom", "model": "hv-fake-1", "route_source": "global"}},
            ]
            out = self._emit_sse([strip_usage(e) for e in events], pace)
            record_run_transcript(run, "HV-FAKE-TOOL-DONE")
            return out
        if run and "HV_APPROVAL" in inp:
            head, req_id, resumed = self._approval_events(run, inp)
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            try:
                self.wfile.write(b": open\n\n")
                last = int(self.headers.get("Last-Event-ID") or -1)
                i = 0
                # Reprise : rejouer head+tail déjà émis après Last-Event-ID, sans recréer l'approbation.
                with LOCK:
                    cached = RUN_SSE.get(run) or {}
                    prior_choice = cached.get("choice")
                    prior_tail = cached.get("tail")
                if resumed and prior_tail is not None:
                    replay = list(head) + list(prior_tail)
                    for ev in replay:
                        if i <= last:
                            i += 1
                            continue
                        ev = dict(strip_usage(ev), seq=i, timestamp=time.time())
                        log_sse(ev)
                        self.wfile.write(("id: %d\ndata: %s\n\n" % (i, json.dumps(ev, ensure_ascii=False))).encode()); self.wfile.flush()
                        i += 1
                        time.sleep(pace)
                    self.wfile.write(b": stream closed\n\n"); self.wfile.flush()
                    return
                for ev in head:
                    if i <= last:
                        i += 1
                        continue
                    ev = dict(strip_usage(ev), seq=i, timestamp=time.time())
                    log_sse(ev)
                    self.wfile.write(("id: %d\ndata: %s\n\n" % (i, json.dumps(ev, ensure_ascii=False))).encode()); self.wfile.flush()
                    i += 1
                    time.sleep(pace)
                if prior_choice is not None:
                    choice = prior_choice
                else:
                    gate = PENDING.get(run, {}).get("gate")
                    # attend la décision (ou coupure / kill) ; keepalives pour le client
                    # Coupure / down : garder le flux ouvert (la feuille reste) ; seul POST /approval
                    # reçoit 503 — sinon un break émet deny et hd.approval.status n'apparaît jamais.
                    while gate is not None and not gate.wait(1.0):
                        self.wfile.write(b": keepalive\n\n"); self.wfile.flush()
                    choice = (PENDING.get(run) or {}).get("choice") or "deny"
                if choice in ("once", "session", "always"):
                    tail = [
                        {"event": "approval.responded", "run_id": run, "choice": choice, "request_id": req_id, "resolved": 1},
                        {"event": "tool.completed", "run_id": run, "tool": "file.write", "duration": 0.05, "error": False,
                         "preview": "{\"ok\": true}"},
                        {"event": "message.delta", "run_id": run, "delta": "Fichier /tmp/hv.txt écrit"},
                        {"event": "run.completed", "run_id": run, "output": "Fichier /tmp/hv.txt écrit", "completed": True,
                         "partial": False, "interrupted": False,
                         "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0},
                         "runtime": {"provider": "custom", "model": "hv-fake-1", "route_source": "global"}},
                    ]
                else:
                    tail = [
                        {"event": "approval.responded", "run_id": run, "choice": "deny", "request_id": req_id, "resolved": 1},
                        {"event": "tool.completed", "run_id": run, "tool": "file.write", "duration": 0.05, "error": True,
                         "preview": "{\"error\": \"denied\"}"},
                        {"event": "message.delta", "run_id": run, "delta": "Refus pris en compte"},
                        {"event": "run.completed", "run_id": run, "output": "Refus pris en compte", "completed": True,
                         "partial": False, "interrupted": False,
                         "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0},
                         "runtime": {"provider": "custom", "model": "hv-fake-1", "route_source": "global"}},
                    ]
                with LOCK:
                    if run in RUN_SSE:
                        RUN_SSE[run]["tail"] = list(tail)
                        RUN_SSE[run]["choice"] = choice
                for ev in tail:
                    if i <= last:
                        i += 1
                        continue
                    ev = dict(strip_usage(ev), seq=i, timestamp=time.time())
                    log_sse(ev)
                    self.wfile.write(("id: %d\ndata: %s\n\n" % (i, json.dumps(ev, ensure_ascii=False))).encode()); self.wfile.flush()
                    i += 1
                    time.sleep(pace)
                self.wfile.write(b": stream closed\n\n"); self.wfile.flush()
                # transcript pour reread : Oui écrit le fichier, Non/Échap annonce le refus
                record_run_transcript(run, "Fichier /tmp/hv.txt écrit" if choice in ("once", "session", "always") else "Refus pris en compte")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        if run and "HV_TOOL_SHELL" in inp:
            # délai volontaire : XCTest doit pouvoir voir hd.tool.current avant tool.completed
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            try:
                self.wfile.write(b": open\n\n")
                seq = 0
                for ev, wait in (
                    ({"event": "tool.started", "run_id": run, "tool": "shell.exec", "preview": "echo ok"}, 1.2),
                    ({"event": "tool.completed", "run_id": run, "tool": "shell.exec", "duration": 0.05, "error": False, "preview": "ok"}, pace),
                    ({"event": "message.delta", "run_id": run, "delta": "Outil terminé"}, pace),
                    ({"event": "run.completed", "run_id": run, "output": "Outil terminé", "completed": True,
                      "partial": False, "interrupted": False,
                      "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0},
                      "runtime": {"provider": "custom", "model": "hv-fake-1", "route_source": "global"}}, pace),
                ):
                    ev = dict(strip_usage(ev), seq=seq, timestamp=time.time())
                    log_sse(ev)
                    self.wfile.write(("id: %d\ndata: %s\n\n" % (seq, json.dumps(ev, ensure_ascii=False))).encode()); self.wfile.flush()
                    seq += 1
                    time.sleep(wait)
                self.wfile.write(b": stream closed\n\n"); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            record_run_transcript(run, "Outil terminé")
            return
        events = [fill(e, v) for e in C["events"]] + list(INJ)
        # tours ordinaires : retirer l'auto-réponse d'approbation de la fixture (sinon la feuille HV_APPROVAL ne s'ouvre jamais).
        # Garder approval.* pour HV_APPROVAL (UI) et HV_TOOL_DETACH (acceptance approve du contract-check).
        if "HV_APPROVAL" not in inp and "HV_TOOL_DETACH" not in inp:
            events = [e for e in events if not (isinstance(e, dict) and str(e.get("event", "")).startswith("approval."))]
        if STATE["omit_tokens"]:
            events = [strip_usage(ev) for ev in events]
        out = self._emit_sse(events, pace)
        # texte assistant de la fixture (ou dernier message.delta injecté)
        assistant = "Réponse de test"
        for e in reversed(events):
            if isinstance(e, dict) and e.get("event") == "message.delta" and e.get("delta"):
                assistant = e.get("delta")
                break
            if isinstance(e, dict) and e.get("event") == "run.completed" and e.get("output"):
                assistant = e.get("output")
                break
        if run:
            record_run_transcript(run, assistant)
        return out
    def _handle(self, method):
        path = self.path.split("?")[0]
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        with LOCK:
            LOG.append({"t": time.time(), "m": method, "p": path, "body": body})
            self._log_i = len(LOG) - 1
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
        if path == "/_hv/profile-models":
            if method != "POST":
                return self._send(404, {"error": "404: Not Found"})
            try:
                obj = json.loads(body or "{}")
            except ValueError:
                return self._send(400, err(None, "Invalid JSON"))
            if not isinstance(obj, dict):
                return self._send(400, err(None, "Invalid body"))
            for k, val in obj.items():
                PROFILE_MODELS[str(k)] = str(val)
            return self._send(200, {"ok": True})
        if path == "/_hv/profile-list":
            return self._send_text(200, profile_list_text())
        if path == "/_hv/inject":
            INJ.append(json.loads(body or "{}")); return self._send(200, {"ok": True})
        if path == "/_hv/cut":
            CUT_UNTIL[0] = time.time() + float(json.loads(body or "{}").get("seconds", 5)); return self._send(200, {"ok": True})
        if time.time() < CUT_UNTIL[0] or STATE["mode"] == "down": return self._send(503, {"error": "unavailable"})
        name, c, v = match(method, path)
        open_unscoped = bool(c and c.get("auth") is False and "profile" not in v)
        header = self.headers.get("Authorization")
        if not open_unscoped:
            if STATE["reject_key"]:
                return self._send(401, err("gateway_auth_failed", "Invalid gateway API key (API_SERVER_KEY)", "gateway_auth_error"))
            if KEYS is not None:
                want = KEYS.get(v.get("profile")) if v.get("profile") else None
                if not want or header != "Bearer " + want:
                    return self._send(401, err("gateway_auth_failed", "Invalid gateway API key (API_SERVER_KEY)", "gateway_auth_error"))
            elif KEY and header != "Bearer " + KEY:
                return self._send(401, err("gateway_auth_failed", "Invalid gateway API key (API_SERVER_KEY)", "gateway_auth_error"))
        if STATE["mode"] == "slow": time.sleep(8)
        if not c or (STATE["mode"] == "drop-route" and name == STATE["drop"]): return self._send(404, {"error": "404: Not Found"})
        served = served_profiles()
        if "profile" in v and v["profile"] not in served: return self._send(404, {"error": "Unknown or unconfigured profile"})
        if "run" in v and v["run"] not in RUNS: return self._send(404, err("run_not_found", "Run not found: " + v["run"]))
        if "run" in v:
            _rmeta = RUN_INPUT.get(v["run"])
            _owner = _rmeta.get("profile") if isinstance(_rmeta, dict) else None
            if _owner is not None and v.get("profile") != _owner:
                return self._send(403, err("forbidden", "Run belongs to another profile"))
        if "session" in v:
            profile = v.get("profile")
            owned = SESSIONS.get(profile) if profile is not None else None
            if owned is None or v["session"] not in owned:
                return self._send(404, err("session_not_found", "Session not found: " + v["session"]))
        if method == "POST" and "body" in c:  # une clé de `body` absente ou vide donne 400, comme Hermes
            try: j = json.loads(body or "{}")
            except ValueError: return self._send(400, err(None, "Invalid JSON"))
            if not isinstance(j, dict) or [k for k in c["body"] if j.get(k) in (None, "")]: return self._send(400, err(None, "Missing field"))
        v = dict(v, new_run="run_" + uuid.uuid4().hex, new_session="api_%d_%s" % (time.time(), uuid.uuid4().hex[:8]))
        if name == "start_run":
            RUNS.add(v["new_run"])
            try:
                posted_run = json.loads(body or "{}")
            except ValueError:
                posted_run = {}
            if isinstance(posted_run, dict):
                RUN_INPUT[v["new_run"]] = {
                    "input": posted_run.get("input") or "",
                    "session": posted_run.get("session_id") or posted_run.get("session") or v.get("session"),
                    "profile": v.get("profile"),
                }
                if posted_run.get("model"):
                    # le corps du run porte le modèle (S4) : utile au journal / runtime
                    v = dict(v, model=posted_run.get("model"))
        if name == "new_session":
            profile = v.get("profile")
            SESSIONS.setdefault(profile, set()).add(v["new_session"])
            SESSION_MSGS[(profile, v["new_session"])] = []  # transcript vide après création
        if name == "set_model" and not (STATE["mode"] == "malformed" and MALFORMED == "nolock"): MODEL[(v.get("profile"), v["session"])] = json.loads(body)["model"]
        if name == "send_message":  # le chat de session lit le verrou de modèle (S4)
            pk = (v.get("profile"), v["session"])
            MSGS[pk] = MSGS.get(pk, 0) + 1
            v = dict(v, model=MODEL.get(pk, "hv-fake-1"), route_source="session_model_lock" if pk in MODEL else "global", n=str(MSGS[pk]))
            try:
                posted = json.loads(body or "{}")
            except ValueError:
                posted = {}
            user_txt = posted.get("input") or posted.get("content") or "hv-probe"
            bucket = SESSION_MSGS.setdefault((v.get("profile"), v["session"]), [])
            bucket.append({"id": 1000 + len(bucket), "session_id": v["session"], "role": "user", "content": user_txt, "tool_call_id": None, "tool_calls": None, "tool_name": None, "timestamp": time.time(), "token_count": None, "finish_reason": None, "reasoning": None, "reasoning_content": None, "display_kind": None})
            bucket.append({"id": 1000 + len(bucket), "session_id": v["session"], "role": "assistant", "content": "HV-FAKE-REPLY model=%s user_msgs=%s" % (v["model"], v["n"]), "tool_call_id": None, "tool_calls": None, "tool_name": None, "timestamp": time.time(), "token_count": None, "finish_reason": "stop", "reasoning": None, "reasoning_content": None, "display_kind": None})
        if c["response"] == "SSE": return self._stream(v)
        resp = fill(c["response"], v)
        if name == "session_messages":
            sid = v.get("session")
            profile = v.get("profile")
            resp = {"object": "list", "session_id": sid, "data": list(SESSION_MSGS.get((profile, sid), []))}
        if name == "list_sessions":
            # les verrous MODEL se voient dans la liste (HD-10 nom inconnu / modèle d'un fil)
            # les sessions créées pendant le test doivent apparaître (Nouvelle session / premier envoi)
            profile = v.get("profile")
            data = list(resp.get("data") or [])
            out = []
            seen = set()
            for row in data:
                row = dict(row)
                sid = row.get("id")
                if (profile, sid) in MODEL:
                    row["model"] = MODEL[(profile, sid)]
                out.append(row)
                if sid:
                    seen.add(sid)
            for sid in list(SESSIONS.get(profile, ())):
                if sid in seen:
                    continue
                out.append(session_row(sid, profile=profile))
                seen.add(sid)
            resp = dict(resp, data=out)
        if name == "version":
            resp = dict(resp, version=STATE["version"])
        if name == "set_model":
            try:
                posted_model = json.loads(body or "{}").get("model")
            except ValueError:
                posted_model = None
            if posted_model and isinstance(resp, dict):
                resp = json.loads(json.dumps(resp))
                rt = dict(resp.get("runtime") or {})
                rt["model"] = posted_model
                req = dict(rt.get("requested") or {})
                req["model"] = posted_model
                rt["requested"] = req
                resp["runtime"] = rt
        if name == "approve":
            try:
                posted = json.loads(body or "{}")
            except ValueError:
                posted = {}
            if isinstance(resp, dict) and isinstance(posted, dict):
                if posted.get("choice") is not None:
                    resp["choice"] = posted["choice"]
                if posted.get("request_id") is not None:
                    resp["request_id"] = posted["request_id"]
            run_id = v.get("run")
            # les sondes de capacité (hd-probe / en-tête) ne doivent pas ouvrir la porte d'un vrai tour
            is_probe = self.headers.get("X-Hermed-Capability-Probe") == "1" or "hd-probe" in str(run_id or "")
            if run_id in PENDING and isinstance(posted, dict) and not is_probe:
                PENDING[run_id]["choice"] = posted.get("choice")
                PENDING[run_id]["gate"].set()
        self._send(c.get("status", 200), mutate(resp) if STATE["mode"] == "fields" else corrupt(resp) if STATE["mode"] == "malformed" else resp)
    def do_GET(self): self._handle("GET")
    def do_POST(self): self._handle("POST")

srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
print("fake-hermes", C["version"], a.mode, a.port, flush=True)
srv.serve_forever()
