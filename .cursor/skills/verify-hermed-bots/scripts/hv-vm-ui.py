#!/usr/bin/env python3
"""Passe UI réelle : hôte (VM + tunnel inverse) ou invité (xcodebuild). Modèle : aucun."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
USAGE = """usage:
  python3 hv-vm-ui.py [--help]
  python3 hv-vm-ui.py              # hôte : VM, tunnel inverse, hv-run.sh ui
  python3 hv-vm-ui.py guest <evidence> <xctestrun>
Codes : 0 PASS | 2 usage | 3 PAUSE | 6 VM en attente | 10 FAIL | 12 référence
        manquante | 15 capture absente | 20 chemin protégé | 22 cible refusée
        | 40 build-for-testing ou xctestrun absent. Les codes de hv-run.sh
        sont renvoyés tels quels.
"""


def log(msg: str) -> None:
    print(msg, flush=True)


def runner_dir() -> Path | None:
    raw = os.environ.get("HV_RUNNER_DIR")
    return Path(raw) if raw else None


def vm_sh() -> Path | None:
    root = runner_dir()
    return (root / "vm.sh") if root else None


def guard_target(host: str) -> int:
    guard = HERE / "hv-guard.sh"
    proc = subprocess.run(["bash", str(guard), "target", host], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 22 if proc.returncode == 22 else proc.returncode


def load_ui_secrets() -> tuple[str, str]:
    """Lit les deux clés hors dépôt. Ne les imprime jamais."""
    work = Path(os.environ.get("HV_WORK") or (Path.home() / "hermed-bots-work"))
    path = Path(os.environ.get("HV_UI_KEYS_FILE") or (work / "secrets" / "hv-ui-keys.json"))
    raw_env = os.environ.get("HV_TEST_API_KEYS")
    if raw_env:
        keys = json.loads(raw_env)
    else:
        keys = json.loads(path.read_text(encoding="utf-8"))
    if set(keys) != {"hv-bot-a", "hv-bot-b"}:
        raise ValueError("hv-ui-keys.json doit porter exactement hv-bot-a et hv-bot-b")
    table = os.environ.get("HV_TEST_PROFILE_TABLE") or (
        "Profile Model Gateway\nhv-bot-a hv-fake-1 running\nhv-bot-b hv-fake-1 running\n"
    )
    packed = json.dumps(keys, separators=(",", ":"))
    return packed, table


def guest(evidence: str, xctestrun: str) -> int:
    evd = Path(evidence)
    evd.mkdir(parents=True, exist_ok=True)
    if shutil.which("xcodebuild") is None or not Path(xctestrun).is_file():
        log("xcodebuild ou HV_XCTESTRUN absent")
        return 40
    try:
        packed, table = load_ui_secrets()
    except (OSError, ValueError, json.JSONDecodeError):
        log("clés de test absentes ou illisibles (fichier privé hors dépôt)")
        return 32
    port = os.environ.get("HV_PORT", "18642")
    url = os.environ.get("HV_API_URL", "http://127.0.0.1:%s" % port)
    env = os.environ.copy()
    env["HV_TEST_API_KEYS"] = packed
    env["HV_TEST_PROFILE_TABLE"] = table
    env["TEST_RUNNER_HV_TEST_MODE"] = "1"
    env["TEST_RUNNER_HV_TEST_API_KEYS"] = packed
    env["TEST_RUNNER_HV_TEST_PROFILE_TABLE"] = table
    env["TEST_RUNNER_HV_API_URL"] = url
    env["TEST_RUNNER_HV_SHOTS"] = str(evd / "shots")
    log_path = evd / "xcodebuild.log"
    cmd = [
        "xcodebuild",
        "test-without-building",
        "-xctestrun",
        xctestrun,
        "-destination",
        "platform=macOS",
        "-resultBundlePath",
        str(evd / "result.xcresult"),
    ]
    with log_path.open("w", encoding="utf-8") as fh:
        proc = subprocess.run(cmd, env=env, stdout=fh, stderr=subprocess.STDOUT)
    return 10 if proc.returncode else 0


def start_reverse_tunnel(port: str) -> subprocess.Popen | None:
    vm = vm_sh()
    if vm is None or not vm.is_file():
        return None
    spec = "127.0.0.1:%s:127.0.0.1:%s" % (port, port)
    cmd = [
        "zsh",
        str(vm),
        "ssh",
        "--",
        "-N",
        "-T",
        "-o",
        "ExitOnForwardFailure=yes",
        "-R",
        spec,
    ]
    try:
        return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return None


def host() -> int:
    t0 = time.time()
    runner = runner_dir()
    if runner is None:
        log("HV_RUNNER_DIR requis")
        return 2
    if (runner / "PAUSE").exists():
        log("PAUSE présent : rien lancé")
        return 3
    vm = vm_sh()
    if vm is None or not vm.is_file():
        log("HV-UI SAUTÉE")
        log("HV-UI chemin=attente rc=6 durée=%.0f preuves=aucune" % (time.time() - t0))
        return 6
    target = os.environ.get("HV_TARGET_HOST", "hv-hermes-test")
    if guard_target(target) == 22:
        log("cible refusée")
        return 22
    port = os.environ.get("HV_PORT", "18642")
    tunnel = start_reverse_tunnel(port)
    if tunnel is None or tunnel.poll() is not None:
        if tunnel is not None:
            tunnel.terminate()
        log("HV-UI SAUTÉE")
        log("HV-UI chemin=attente rc=6 durée=%.0f preuves=aucune" % (time.time() - t0))
        return 6
    env = os.environ.copy()
    env.setdefault("HV_UI_BACKEND", "orb")
    env.setdefault("HV_UNDER_RUNNER", "1")
    env.setdefault("HV_API_URL", "http://127.0.0.1:%s" % port)
    try:
        packed, table = load_ui_secrets()
        env["HV_TEST_API_KEYS"] = packed
        env["HV_TEST_PROFILE_TABLE"] = table
    except (OSError, ValueError, json.JSONDecodeError):
        packed = None
    xctestrun = os.environ.get("HV_XCTESTRUN", "")
    if xctestrun and not Path(xctestrun).is_file():
        if tunnel is not None:
            tunnel.terminate()
        log("xcodebuild ou HV_XCTESTRUN absent")
        return 40
    work = Path(os.environ.get("HV_WORK") or (Path.home() / "hermed-bots-work"))
    dd = work / "dd"
    if not xctestrun:
        build = [
            "zsh",
            str(vm),
            "exec",
            "env",
            "HV_UI_BACKEND=orb",
            "xcodebuild",
            "build-for-testing",
            "-scheme",
            "HermedBots",
            "-destination",
            "platform=macOS",
            "-derivedDataPath",
            str(dd),
        ]
        built = subprocess.run(build, env=env)
        if built.returncode != 0:
            if tunnel is not None:
                tunnel.terminate()
            log("build-for-testing en échec")
            return 40
        products = dd / "Build" / "Products"
        found = sorted(products.glob("*.xctestrun")) if products.is_dir() else []
        if not found:
            if tunnel is not None:
                tunnel.terminate()
            log("xcodebuild ou HV_XCTESTRUN absent")
            return 40
        env["HV_XCTESTRUN"] = str(found[0])
    cmd = [
        "zsh",
        str(vm),
        "exec",
        "env",
        "HV_UI_BACKEND=orb",
        "bash",
        ".cursor/skills/verify-hermed-bots/scripts/hv-run.sh",
        "ui",
        "fake",
    ]
    try:
        proc = subprocess.run(cmd, env=env)
        rc = proc.returncode
    finally:
        if tunnel is not None and tunnel.poll() is None:
            tunnel.terminate()
            try:
                tunnel.wait(timeout=5)
            except subprocess.TimeoutExpired:
                tunnel.kill()
    if rc in (6,):
        log("HV-UI SAUTÉE")
        chemin = "attente"
    else:
        chemin = "vm"
    preuves = os.environ.get("HV_EVIDENCE", "")
    log("HV-UI chemin=%s rc=%s durée=%.0f preuves=%s" % (chemin, rc, time.time() - t0, preuves or "vm"))
    return rc


def main(argv: list[str]) -> int:
    if "--help" in argv or "-h" in argv:
        sys.stdout.write(USAGE)
        return 0
    if not argv:
        return host()
    if argv[0] == "guest":
        if len(argv) != 3:
            sys.stderr.write(USAGE)
            return 2
        return guest(argv[1], argv[2])
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
