#!/usr/bin/env python3
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def request(port, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    connection.request(method, path, json.dumps(body).encode() if body is not None else None, headers or {})
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, data


backend, proxy = free_port(), free_port()
environment = {"PATH": os.environ["PATH"], "HD13_BACKEND": str(backend), "HD13_PORT": str(proxy)}
processes = []
try:
    processes.append(subprocess.Popen([sys.executable, str(ROOT / ".cursor/skills/verify-hermed-bots/scripts/hv-fake-hermes.py"), "--port", str(backend)], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    processes.append(subprocess.Popen([sys.executable, str(Path(__file__).with_name("cut-proxy.py"))], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for port in (backend, proxy):
        for _ in range(100):
            try:
                assert request(port, "GET", "/_hv/ready")[0] == 200
                break
            except OSError:
                time.sleep(0.05)
        else:
            raise AssertionError("server not ready")
    assert request(proxy, "GET", "/p/hv-bot-a/v1/runs/missing/events")[0] == 404
    session = json.loads(request(proxy, "POST", "/p/hv-bot-a/api/sessions", {})[1])["session"]["id"]
    path = "/p/hv-bot-a/v1/runs"
    message = {"input": "HV_SLOW proxy check", "session_id": session}
    status, data = request(proxy, "POST", path, message, {"Idempotency-Key": "one"})
    assert status == 202
    run = json.loads(data)["run_id"]
    assert request(proxy, "POST", path, message, {"Idempotency-Key": "one"}) == (status, data)
    reordered = {"session_id": session, "input": message["input"]}
    assert request(proxy, "POST", path, reordered, {"Idempotency-Key": "one"}) == (status, data)
    assert request(proxy, "POST", path, {"input": "different"}, {"Idempotency-Key": "one"})[0] == 409
    connection = http.client.HTTPConnection("127.0.0.1", proxy, timeout=20)
    connection.request("GET", path + "/" + run + "/events")
    stream = connection.getresponse()
    assert stream.readline().startswith(b": open")
    request(proxy, "POST", "/_hv/cut", {"seconds": 0.2})
    stream.read()
    connection.close()
    assert request(proxy, "GET", path + "/" + run + "/events")[0] == 503
    time.sleep(0.3)
    status, replay = request(proxy, "GET", path + "/" + run + "/events")
    assert status == 200 and b'"event": "run.completed"' in replay
    log = json.loads(request(proxy, "GET", "/_hv/log")[1])
    assert len([entry for entry in log if entry["p"] == path]) == 1
    request(proxy, "POST", "/_hv/ack-cut", {})
    try:
        request(proxy, "POST", path, message, {"Idempotency-Key": "two"})
        raise AssertionError("the admission acknowledgement was not lost")
    except http.client.RemoteDisconnected:
        pass
    request(proxy, "POST", "/_hv/cut", {"seconds": 0})
    status, acknowledged = request(proxy, "POST", path, message, {"Idempotency-Key": "two"})
    assert status == 202 and json.loads(acknowledged)["run_id"] != run
    request(proxy, "POST", "/_hv/inject", {"event": "run.completed"})
    _, injected = request(proxy, "GET", path + "/" + json.loads(acknowledged)["run_id"] + "/events")
    assert b'"seq":100000' in injected and b'Injected completion' in injected
    log = json.loads(request(proxy, "GET", "/_hv/log")[1])
    assert len([entry for entry in log if entry["p"] == path]) == 2
    print("PROXY OK: cut closes an open stream, run continues, replay completes, idempotent admission and conflict")
finally:
    for process in processes:
        process.terminate()
    for process in processes:
        process.wait(timeout=10)
