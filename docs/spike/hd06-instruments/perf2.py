#!/usr/bin/env python3
"""perf2.py : cinq lancements à froid de l'app ; heure de lancement (exec) jusqu'à l'heure où hd.status.version expose la version dans l'arbre AX (sonde dans le processus)"""
import datetime, json, os, signal, statistics, subprocess, sys, time, urllib.request, zoneinfo

HOME = os.path.expanduser("~")
APP = HOME + "/hermed-bots-work/dd/Build/Products/Debug/HermedBots.app/Contents/MacOS/HermedBots"
PROBE = HOME + "/hermed-bots-work/hd06-scripts/hv-ax-probe.dylib"
OUT = HOME + "/hermed-bots-work/evidence/hd06/probe.txt"
URL = "http://127.0.0.1:18642"


def stamp():
    return datetime.datetime.now(zoneinfo.ZoneInfo("Europe/Paris")).strftime("[%H:%M:%S Paris]")


def server_log():
    return json.load(urllib.request.urlopen(URL + "/_hv/log", timeout=3))


results, healths = [], []
for run in range(1, 6):
    open(OUT, "w").close()
    base = len(server_log())
    env = dict(os.environ, HV_TEST_MODE="1", HV_API_URL=URL, DYLD_INSERT_LIBRARIES=PROBE, HV_PROBE_OUT=OUT)
    t0 = time.time()
    proc = subprocess.Popen([APP, "-AppleLanguages", "(fr)"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    seen = None
    while time.time() < t0 + 15 and seen is None:
        line = open(OUT).read().strip()
        if line:
            seen = line.split("\t")
        time.sleep(0.005)
    new = [e for e in server_log()[base:] if e["p"] == "/health"]
    os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    if seen is None:
        print("%s HV-PERF cold-launch run=%d ÉCHEC : la version n'apparaît pas en 15 s" % (stamp(), run))
        sys.exit(1)
    visible = float(seen[0]) - t0
    health = new[0]["t"] - t0 if new else None
    results.append(visible)
    healths.append(health)
    print("%s HV-PERF cold-launch run=%d exec→GET /health reçu=%d ms ; exec→hd.status.version=%s dans l'arbre AX=%d ms" % (stamp(), run, health * 1000, seen[1], visible * 1000))
    time.sleep(1)
print("%s HV-PERF médiane exec→hd.status.version visible=%d ms (min %d, max %d) ; médiane exec→GET /health=%d ms ; budget=2000 ms" % (stamp(), statistics.median(results) * 1000, min(results) * 1000, max(results) * 1000, statistics.median(healths) * 1000))
sys.exit(0 if statistics.median(results) <= 2.0 else 1)
