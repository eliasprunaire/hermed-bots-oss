#!/usr/bin/env python3
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[3]
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
server = subprocess.Popen(
    [sys.executable, str(root / ".cursor/skills/verify-hermed-bots/scripts/hv-fake-hermes.py"), "--port", str(port)],
    env={**os.environ, "HV_TEST_API_KEY": ""}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)

def request(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}" + path, data), timeout=12) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()

try:
    for attempt in range(100):
        try:
            assert request("/_hv/ready")[0] == 200
            break
        except OSError:
            time.sleep(0.1)
    else:
        raise AssertionError("fake not ready")
    assert request("/_hv/config", [])[0] == 400
    assert request("/_hv/config", {"mode": "invalid"})[0] == 400
    assert request("/_hv/config", {"mode": "down"})[0] == 200
    assert request("/health")[0] == 503
    request("/_hv/config", {"mode": "normal", "reject_key": True})
    assert request("/p/hv-bot-a/v1/models")[0] == 401
    request("/_hv/config", {"mode": "drop-route", "drop": "approve"})
    assert request("/p/hv-bot-a/v1/runs/hd-probe-capabilities/approval", {})[0] == 404
    request("/_hv/profile-models", {"hv-bot-b": "model-y"})
    assert "model-y" in request("/_hv/profile-list")[1].decode()
    request("/_hv/config", {"mode": "normal", "version": "0.22.1", "omit_tokens": True})
    assert json.loads(request("/health")[1])["version"] == "0.22.1"
    status, body = request("/p/hv-bot-a/v1/runs", {"input": "HV_LOOP go"})
    assert status == 202
    run = json.loads(body)["run_id"]
    status, body = request(f"/p/hv-bot-a/v1/runs/{run}/events")
    events = [json.loads(line[6:]) for line in body.decode().splitlines() if line.startswith("data: ")]
    assert sum(event["event"] == "tool.started" for event in events) == 3
    assert all("usage" not in event for event in events)
    assert events[-1]["event"] == "run.completed"
    print("HD12 fake controls, refused key, retry recovery, version, repeated calls, missing tokens: PASS")
finally:
    server.terminate()
    server.wait(timeout=5)
