#!/usr/bin/env python3
"""A loopback proxy that cuts open streams while the fixture run continues."""
import http.client
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKEND = int(os.environ.get("HD13_BACKEND", "18643"))
CUT = 0.0
GENERATION = 0
STREAMS = {}
RUN_PATHS = set()
ADMISSIONS = {}
ACK_CUT = False
LOCK = threading.RLock()


def fetch(method, path, body, headers):
    conn = http.client.HTTPConnection("127.0.0.1", BACKEND, timeout=900)
    conn.request(method, path, body, headers)
    return conn, conn.getresponse()


def collect(path, headers, state):
    try:
        conn, response = fetch("GET", path, None, headers)
        pending = b""
        while True:
            chunk = response.read1(65536)
            if not chunk:
                break
            with LOCK:
                if state["done"]:
                    break
                pending += chunk
                while b"\n\n" in pending:
                    frame, pending = pending.split(b"\n\n", 1)
                    state["chunks"].append(frame + b"\n\n")
        conn.close()
    finally:
        with LOCK:
            state["done"] = True


class Proxy(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def close_link(self):
        self.close_connection = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_request(self):
        global CUT, GENERATION, ACK_CUT
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection", "content-length")}
        path = self.path
        if path == "/_hv/profile-locks":
            self.reply(503 if time.monotonic() < CUT else 200, b'{"held":[]}')
            return
        if path == "/_hv/cut":
            with LOCK:
                CUT = time.monotonic() + float(json.loads(body)["seconds"])
                GENERATION += 1
            self.reply(200, b'{}')
            return
        if path == "/_hv/ack-cut":
            ACK_CUT = True
            self.reply(200, b'{}')
            return
        if path == "/_hv/inject" and json.loads(body).get("event") == "run.completed":
            with LOCK:
                for state in STREAMS.values():
                    if not state["done"]:
                        state["chunks"].append(b'id: 100000\ndata: {"event":"run.completed","seq":100000,"output":"Injected completion"}\n\n: stream closed\n\n')
                        state["done"] = True
            self.reply(200, b'{}')
            return
        if not path.startswith("/_hv/") and time.monotonic() < CUT:
            self.reply(503, b'{}')
            return
        if self.command == "GET" and path in RUN_PATHS:
            with LOCK:
                state = STREAMS.get(path)
                if state is None:
                    state = {"chunks": [], "done": False}
                    STREAMS[path] = state
                    threading.Thread(target=collect, args=(path, headers, state), daemon=True).start()
                generation = GENERATION
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            offset = 0
            while True:
                with LOCK:
                    if generation != GENERATION:
                        self.close_link()
                        return
                    chunks = state["chunks"][offset:]
                    offset += len(chunks)
                    done = state["done"]
                for chunk in chunks:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                if done:
                    return
                time.sleep(0.02)
        key = self.headers.get("Idempotency-Key") if path.endswith("/v1/runs") else None
        if key and key in ADMISSIONS:
            previous, status, data = ADMISSIONS[key]
            same = previous == json.loads(body)
            self.reply(status if same else 409, data if same else b'{}')
            return
        conn, response = fetch(self.command, path, body, headers)
        data = response.read()
        status = response.status
        conn.close()
        if key and status == 202:
            ADMISSIONS[key] = (json.loads(body), status, data)
        if status == 202 and path.endswith("/v1/runs"):
            RUN_PATHS.add(path + "/" + json.loads(data)["run_id"] + "/events")
            if ACK_CUT:
                ACK_CUT = False
                CUT = time.monotonic() + 10
                GENERATION += 1
                run = json.loads(data)["run_id"]
                events = path + "/" + run + "/events"
                state = {"chunks": [], "done": False}
                STREAMS[events] = state
                threading.Thread(target=collect, args=(events, headers, state), daemon=True).start()
                self.close_link()
                return
        if path == "/_hv/reset":
            with LOCK:
                STREAMS.clear()
                RUN_PATHS.clear()
                ADMISSIONS.clear()
                CUT = 0.0
                ACK_CUT = False
        self.reply(status, data)

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("HD13_PORT", "18642"))), Proxy).serve_forever()
