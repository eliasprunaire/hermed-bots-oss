#!/usr/bin/env python3
"""Vérifie l'authentification par profil et l'absence des clés dans le journal fake."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]
keys = {p: secrets.token_urlsafe(32) for p in ['default', 'cyber', 'ia']}
base = f'http://127.0.0.1:{port}'


def request(path, key=None):
    headers = {'Authorization': 'Bearer ' + key} if key else {}
    try:
        with urllib.request.urlopen(urllib.request.Request(base + path, headers=headers), timeout=2) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


with tempfile.TemporaryFile() as log:
    server = subprocess.Popen([sys.executable, str(ROOT / '.cursor/skills/verify-hermed-bots/scripts/hv-fake-hermes.py'), '--port', str(port)], env=dict(os.environ, HV_TEST_API_KEYS=json.dumps(keys)), stdout=log, stderr=log)
    try:
        for _ in range(50):
            try:
                if request('/_hv/ready')[0] == 200:
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise AssertionError('Faux serveur indisponible')
        for profile, key in keys.items():
            assert request(f'/p/{profile}/v1/models', key)[0] == 200
        assert request('/p/cyber/v1/models', keys['ia'])[0] == 401
        assert request('/p/cyber/v1/models', keys['default'])[0] == 401
        assert request('/p/cyber/v1/models')[0] == 401
        assert request('/p/gaming/v1/models', keys['default'])[0] == 401
        assert request('/health')[0] == 200
        entries = request('/_hv/log')[1]
        assert not any(key.encode() in entries for key in keys.values())
        print('HD17 fake: clés distinctes acceptées, croisement et clé absente refusés, journal sans secret')
    finally:
        server.terminate()
        server.wait(timeout=5)
