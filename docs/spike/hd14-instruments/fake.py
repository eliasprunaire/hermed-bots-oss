#!/usr/bin/env python3
"""Ajoute le canal de détection simulé au faux Hermes, sans filtrer ses écritures."""
import http.client
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import signal
import subprocess
import sys
import threading
import time

PORT = int(os.environ.get('HV_PORT', '18642'))
STATE = {'held': [], 'drop': False}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def handle_request(self):
        size = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(size)
        if self.path == '/_hv/hold':
            update = json.loads(body)
            with LOCK:
                STATE.update(update)
            return self.reply(200, {'ok': True, 'at': time.time()})
        if self.path == '/_hv/profile-locks':
            with LOCK:
                status = 404 if STATE['drop'] else 200
                snapshot = {'held': list(STATE['held'])}
            return self.reply(status, snapshot)
        if self.path == '/_hv/reset':
            with LOCK:
                STATE.update(held=[], drop=False)
        connection = http.client.HTTPConnection('127.0.0.1', PORT + 1, timeout=330)
        try:
            connection.request(self.command, self.path, body, dict(self.headers))
            response = connection.getresponse()
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in ('server', 'date', 'connection', 'transfer-encoding'):
                    self.send_header(key, value)
            self.send_header('Connection', 'close')
            self.end_headers()
            while chunk := response.read1(65536):
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            connection.close()
            self.close_connection = True

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = handle_request
    do_POST = handle_request


if __name__ == '__main__':
    child = subprocess.Popen([sys.executable, '.cursor/skills/verify-hermed-bots/scripts/hv-fake-hermes.py', '--port', str(PORT + 1)])
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
    finally:
        child.terminate()
        child.wait()
