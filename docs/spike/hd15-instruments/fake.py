#!/usr/bin/env python3
"""Proxy de recette HD15. Le serveur existant conserve sessions et transcripts."""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

PORT = int(os.environ.get('HV_PORT', '18642'))
RUNS, LOG, CONFIG = {}, [], {'mode': 'normal', 'drop': ''}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def backend(self, body):
        connection = http.client.HTTPConnection('127.0.0.1', PORT + 1, timeout=330)
        connection.request(self.command, self.path, body, dict(self.headers))
        response = connection.getresponse()
        return connection, response

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/_hv/reset':
            with LOCK:
                for run in RUNS.values():
                    run['cancel'].set()
                RUNS.clear()
                LOG.clear()
                CONFIG.update(mode='normal', drop='')
        if self.path == '/_hv/config':
            CONFIG.update(json.loads(body))
        if self.path.endswith('/v1/capabilities'):
            with LOCK:
                LOG.append({'m': self.command, 'p': self.path, 't': time.time()})
            if CONFIG.get('reject_key'):
                LOG[-1]['s'] = 401
                return self.reply(401, {'error': 'invalid API key'})
            if CONFIG['mode'] == 'down':
                return self.reply(503, {'error': 'unavailable'})
            enabled = not (CONFIG['mode'] == 'drop-route' and CONFIG['drop'] == 'cancel_run')
            return self.reply(200, {'features': {'run_stop': enabled}})
        if self.path == '/_hv/runs':
            return self.reply(200, [{k: v for k, v in r.items() if k != 'cancel'} for r in RUNS.values()])
        if self.path == '/_hv/sessions':
            rows = []
            for run in RUNS.values():
                connection = http.client.HTTPConnection('127.0.0.1', PORT + 1, timeout=5)
                connection.request('GET', f"/p/{run['profile']}/api/sessions/{run['session']}/messages")
                response = connection.getresponse()
                messages = json.loads(response.read()).get('data', [])
                rows.append({'id': run['session'], 'profile': run['profile'], 'messages': len(messages), 'ids': [m['id'] for m in messages], 'http': response.status})
                connection.close()
            return self.reply(200, rows)
        match = re.fullmatch(r'/p/([^/]+)/v1/runs/([^/]+)(/stop|/events)?', self.path)
        if match and match[3] != '/events':
            profile, ident, action = match.groups()
            probe = self.headers.get('X-Hermed-Capability-Probe') == '1'
            row = {'m': self.command, 'p': self.path, 'probe': probe, 't': time.time()}
            with LOCK:
                LOG.append(row)
            if CONFIG['mode'] == 'down':
                return self.reply(503, {'error': 'unavailable'})
            if CONFIG['mode'] == 'drop-route' and CONFIG['drop'] == 'cancel_run' and action == '/stop':
                return self.reply(404, {'error': '404: Not Found'})
            run = RUNS.get(ident)
            if not run or run['profile'] != profile:
                return self.reply(404, {'error': {'code': 'run_not_found', 'message': 'Run not found'}})
            if action == '/stop':
                run.update(status='cancelled', cancelled_at=time.time())
                run['cancel'].set()
            return self.reply(200, {'run_id': ident, 'status': run['status']})
        if match and match[3] == '/events' and match[2] in RUNS:
            run = RUNS[match[2]]
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            def emit(event):
                event.update(run_id=match[2], timestamp=time.time())
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.flush()
            try:
                emit({'event': 'tool.started', 'tool': 'terminal', 'preview': 'sleep 300'})
                if 'APPROVAL' in run['input']:
                    emit({'event': 'approval.request', 'request_id': 'apr_' + match[2], 'command': 'sleep 300', 'choices': ['once', 'deny']})
                while not run['cancel'].wait(1):
                    self.wfile.write(b': keepalive\n\n')
                    self.wfile.flush()
                emit({'event': 'run.cancelled', 'turn_exit_reason': 'interrupted_by_user'})
                self.wfile.write(b': stream closed\n\n')
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
            return
        connection, response = self.backend(body)
        try:
            if self.path == '/_hv/log':
                return self.reply(200, json.loads(response.read()) + LOG)
            if self.command == 'POST' and self.path.endswith('/v1/runs'):
                data = response.read()
                value, payload = json.loads(data), json.loads(body)
                if response.status == 202 and 'HV_KILL' in payload.get('input', ''):
                    RUNS[value['run_id']] = dict(profile=self.path.split('/')[2], input=payload['input'], session=payload.get('session_id'), status='running', cancel=threading.Event())
                return self.reply(response.status, value)
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
