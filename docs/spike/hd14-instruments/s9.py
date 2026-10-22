#!/usr/bin/env python3
"""À exécuter comme hermes dans hv-hermes-test, avec la sonde sur stdin."""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
import psutil

probe = sys.stdin.read()

def snapshot():
    return json.loads(subprocess.check_output([sys.executable, '-c', probe], text=True))

def api(profile):
    request = urllib.request.Request('http://127.0.0.1:8642/p/' + profile + '/v1/models',
                                    headers={'Authorization': 'Bearer ' + os.environ['HV_TEST_API_KEY']})
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.status

# Retire uniquement le backend de cette sonde S9 précédente, jamais le Gateway
for process in psutil.process_iter():
    try:
        args = process.cmdline()
        if 'serve' in args and '--port' in args and args[args.index('--port') + 1] == '18789' and process.environ().get('HERMES_DESKTOP') == '1':
            process.terminate()
            process.wait(timeout=20)
    except psutil.NoSuchProcess:
        pass

result = {'version': '0.22.2', 'container': 'hv-hermes-test', 'gateway_only': snapshot()}
for order in ('desktop-first', 'api-first'):
    if order == 'api-first':
        assert api('hv-bot-a') == 200
    with open(os.devnull, 'w') as sink:
        desktop = subprocess.Popen(['hermes', '--profile', 'hv-bot-a', 'serve', '--isolated', '--host', '127.0.0.1', '--port', '18789'], env=dict(os.environ, HERMES_DESKTOP='1'), stdout=sink, stderr=sink)
        try:
            deadline = time.monotonic() + 30
            ready = False
            while time.monotonic() < deadline and desktop.poll() is None:
                try:
                    with socket.create_connection(('127.0.0.1', 18789), timeout=.5):
                        ready = True
                        break
                except OSError:
                    time.sleep(.1)
            assert ready, f'Desktop backend not listening: exit={desktop.poll()}'
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                found = snapshot()
                if 'hv-bot-a' in found['held']:
                    break
                time.sleep(.1)
            assert desktop.poll() is None
            assert found['held'] == ['hv-bot-a'], found
            result[order] = {'detected': found, 'api_a': api('hv-bot-a'), 'api_b': api('hv-bot-b'), 'backend_alive': True, 'desktop_listening': 18789}
        finally:
            desktop.terminate()
            desktop.wait(timeout=30)
    result[order]['released'] = snapshot()
    assert result[order]['released']['held'] == []
result['desktop_gui'] = 'manual-only: application macOS absente du conteneur Linux ; tunnel OrbStack VM non branché par vm.sh'
print(json.dumps(result, ensure_ascii=False, indent=2))
