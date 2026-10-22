#!/usr/bin/env python3
"""perf-setup.py [nombre] : du lancement de l'app (exec) à la première réponse de GET /health par le port local du tunnel
Mesure de l'extérieur, sans XCUITest : elle isole le coût de l'ouverture du tunnel (agent, ssh, poignée de main, redirection)
Les clés viennent de l'environnement (HV_TEST_SSH_KEY) ; le conteneur doit tourner avec son sshd"""
import os
import re
import signal
import statistics
import subprocess
import sys
import time
import urllib.request

APP = os.environ["APPD"]
runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
env = dict(os.environ, HV_TEST_MODE="1", HV_SSH_HOST="host.example", HV_SSH_USER="hvssh")
samples = []
for i in range(runs):
    t0 = time.monotonic()
    app = subprocess.Popen([APP, "-AppleLanguages", "(fr)"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    answered = None
    while time.monotonic() - t0 < 20:
        table = subprocess.run(["ps", "-Ao", "pid=,ppid=,args="], capture_output=True, text=True).stdout
        port = None
        for line in table.splitlines():
            fields = line.split(None, 2)
            if len(fields) == 3 and fields[1] == str(app.pid):
                found = re.search(r" -L 127\.0\.0\.1:(\d+):", fields[2])
                if found:
                    port = int(found.group(1))
        if port:
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/health" % port, timeout=1).read()
                answered = time.monotonic() - t0
                break
            except Exception:
                pass
        time.sleep(0.02)
    samples.append(answered)
    print("lancement %d : exec -> première réponse de /health par le tunnel : %s" % (i + 1, "%d ms" % (answered * 1000) if answered else "ÉCHEC"))
    app.send_signal(signal.SIGTERM)
    app.wait(timeout=10)
    time.sleep(1)
ok = [s for s in samples if s]
print("médiane %d ms sur %d lancements" % (statistics.median(ok) * 1000, len(ok)))
sys.exit(0 if len(ok) == runs else 1)
