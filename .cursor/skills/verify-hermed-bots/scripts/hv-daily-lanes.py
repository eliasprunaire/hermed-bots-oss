#!/usr/bin/env python3
"""Dix lanes CLI HD-16 et mesures de durée, aucune interface. Modèle : aucun."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
HV_RUN = HERE / "hv-run.sh"
USAGE = """usage: python3 hv-daily-lanes.py [--help] [--out <json>]
Lance les dix lanes CLI de HD-16 (aucun XCUITest, aucune capture).
Mesure la durée wall de `hv-run.sh daily` en mode fake.
Les lanes orb réelles restent notées not-run hors Mac.
"""

LANES = [
    ("1", "daily-fake-head", "hv-run.sh daily fake à HEAD"),
    ("2", "daily-orb", "hv-run.sh daily orb (Mac, neuf profils)"),
    ("3", "absent", "HV_USER_PRESENT=0 → not run"),
    ("4", "guard", "chemin protégé modifié → 20 et ALERTE"),
    ("5", "fail-approve", "route approve retirée → FAIL et ALERTE"),
    ("6", "clean", "passe propre sans ALERTE"),
    ("7", "fallback", "OrbStack absent → repli fake"),
    ("8", "pause", "PAUSE → 3, rien lancé"),
    ("9", "lock", "verrou runner → 4"),
    ("10", "secret", "la clé de test n'apparaît pas dans les preuves"),
]


def script_fingerprints() -> dict[str, str]:
    out = {}
    for path in sorted(HERE.glob("hv-*")):
        if path.suffix in {".pyc"} or path.is_dir():
            continue
        out[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return out


def base_env(home: Path, runner: Path, work: Path, key: str) -> dict[str, str]:
    env = os.environ.copy()
    env["HOME"] = str(home)
    env["HV_RUNNER_DIR"] = str(runner)
    env["HV_WORK"] = str(work)
    env["HV_UNDER_RUNNER"] = "1"
    env["HV_TEST_API_KEY"] = key
    env["HV_USER_PRESENT"] = "1"
    env.pop("HV_FAKE_MODE", None)
    env.pop("HV_DROP", None)
    return env


def run_hv(args: list[str], env: dict[str, str], timeout: int = 600) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(HV_RUN), *args],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=timeout,
    )


def latest_daily(work: Path) -> Path | None:
    evidence = work / "evidence"
    if not evidence.is_dir():
        return None
    days = sorted(evidence.glob("daily-*"), key=lambda p: p.stat().st_mtime)
    return days[-1] if days else None


def report_fields_ok(rep: Path) -> bool:
    text = rep.read_text(encoding="utf-8")
    needed = (
        "Test quotidien Hermes",
        "Version Hermes",
        "Environnement",
        "Repli",
        "Durée",
        "Chemins protégés",
        "Code de sortie",
        "Verdict",
    )
    return all(item in text for item in needed)


def lane1(env: dict[str, str], work: Path) -> dict:
    t0 = time.time()
    proc = run_hv(["daily", "fake"], env)
    dur = time.time() - t0
    evd = latest_daily(work)
    rep = evd / "rapport-quotidien.md" if evd else None
    ok = proc.returncode == 0 and rep is not None and report_fields_ok(rep)
    return {"rc": proc.returncode, "duration_s": round(dur, 3), "pass": ok, "detail": "HEAD daily fake"}


def lane2(env: dict[str, str], work: Path) -> dict:
    if shutil.which("orb") is None or shutil.which("docker") is None:
        return {"rc": None, "duration_s": 0, "pass": None, "detail": "not-run: orb quotidien exige macOS et OrbStack"}
    t0 = time.time()
    proc = run_hv(["daily", "orb"], env)
    dur = time.time() - t0
    evd = latest_daily(work)
    ok = proc.returncode == 0 and evd is not None and (evd / "rapport-quotidien.md").is_file()
    return {"rc": proc.returncode, "duration_s": round(dur, 3), "pass": ok, "detail": "daily orb"}


def lane3(env: dict[str, str], work: Path) -> dict:
    env = dict(env)
    env["HV_USER_PRESENT"] = "0"
    t0 = time.time()
    proc = run_hv(["daily", "fake"], env)
    dur = time.time() - t0
    evd = latest_daily(work)
    text = (evd / "rapport-quotidien.md").read_text(encoding="utf-8") if evd and (evd / "rapport-quotidien.md").is_file() else ""
    ok = "not run" in text and "utilisateur absent" in text
    has_contract = evd is not None and (evd / "contracts.json").is_file()
    return {"rc": proc.returncode, "duration_s": round(dur, 3), "pass": ok and not has_contract, "detail": "absent"}


def lane4(env: dict[str, str], work: Path, home: Path) -> dict:
    env = dict(env)
    t0 = time.time()
    proc = subprocess.Popen(
        ["bash", str(HV_RUN), "daily", "fake"],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.time() + 8
    while time.time() < deadline and proc.poll() is None:
        if (work / "evidence"):
            marked = list((work / "evidence").glob("daily-*"))
            if marked and (marked[-1] / "guard-before.txt").is_file():
                break
        time.sleep(0.2)
    hermes = home / ".local" / "bin"
    hermes.mkdir(parents=True, exist_ok=True)
    (hermes / "hermes").write_text("mutated\n", encoding="utf-8")
    rc = proc.wait()
    dur = time.time() - t0
    evd = latest_daily(work)
    alerte = evd is not None and (evd / "ALERTE").is_file()
    return {"rc": rc, "duration_s": round(dur, 3), "pass": rc == 20 and alerte, "detail": "guard"}


def lane5(env: dict[str, str], work: Path) -> dict:
    env = dict(env)
    env["HV_FAKE_MODE"] = "drop-route"
    env["HV_DROP"] = "approve"
    t0 = time.time()
    proc = run_hv(["daily", "fake"], env)
    dur = time.time() - t0
    evd = latest_daily(work)
    alerte = evd is not None and (evd / "ALERTE").is_file()
    text = ""
    if evd and (evd / "rapport-quotidien.md").is_file():
        text = (evd / "rapport-quotidien.md").read_text(encoding="utf-8")
    ok = proc.returncode != 0 and alerte and "approve" in text and "FAIL" in text
    return {"rc": proc.returncode, "duration_s": round(dur, 3), "pass": ok, "detail": "drop approve"}


def lane6(env: dict[str, str], work: Path) -> dict:
    t0 = time.time()
    proc = run_hv(["daily", "fake"], env)
    dur = time.time() - t0
    evd = latest_daily(work)
    alerte = evd is not None and (evd / "ALERTE").is_file()
    ok = proc.returncode == 0 and not alerte
    return {"rc": proc.returncode, "duration_s": round(dur, 3), "pass": ok, "detail": "clean"}


def lane7(env: dict[str, str], work: Path) -> dict:
    env = dict(env)
    env["PATH"] = "/usr/bin:/bin"
    t0 = time.time()
    proc = run_hv(["daily", "orb"], env)
    dur = time.time() - t0
    evd = latest_daily(work)
    text = (evd / "rapport-quotidien.md").read_text(encoding="utf-8") if evd and (evd / "rapport-quotidien.md").is_file() else ""
    ok = "fake" in text and ("Repli" in text) and ("OrbStack" in text or "repli" in text.lower())
    return {"rc": proc.returncode, "duration_s": round(dur, 3), "pass": ok, "detail": "fallback"}


def lane8(env: dict[str, str], runner: Path) -> dict:
    (runner / "PAUSE").write_text("pause\n", encoding="utf-8")
    t0 = time.time()
    proc = run_hv(["daily", "fake"], env)
    dur = time.time() - t0
    (runner / "PAUSE").unlink(missing_ok=True)
    return {"rc": proc.returncode, "duration_s": round(dur, 3), "pass": proc.returncode == 3, "detail": "PAUSE"}


def lane9(env: dict[str, str], runner: Path) -> dict:
    env = dict(env)
    env.pop("HV_UNDER_RUNNER", None)
    (runner / ".lock").mkdir(exist_ok=True)
    t0 = time.time()
    proc = run_hv(["daily", "fake"], env)
    dur = time.time() - t0
    return {"rc": proc.returncode, "duration_s": round(dur, 3), "pass": proc.returncode == 4, "detail": "lock"}


def lane10(env: dict[str, str], work: Path, key: str) -> dict:
    t0 = time.time()
    proc = run_hv(["daily", "fake"], env)
    dur = time.time() - t0
    leaked = False
    evidence = work / "evidence"
    if evidence.is_dir():
        for path in evidence.rglob("*"):
            if not path.is_file():
                continue
            try:
                data = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if key in data:
                leaked = True
                break
    return {"rc": proc.returncode, "duration_s": round(dur, 3), "pass": (not leaked), "detail": "secret absent" if not leaked else "secret retrouvé"}


def main(argv: list[str]) -> int:
    if "--help" in argv or "-h" in argv:
        sys.stdout.write(USAGE)
        return 0
    out_path = None
    args = list(argv)
    if "--out" in args:
        i = args.index("--out")
        if i + 1 >= len(args):
            sys.stderr.write(USAGE)
            return 2
        out_path = Path(args[i + 1])
        del args[i : i + 2]
    if args:
        sys.stderr.write(USAGE)
        return 2
    key = "hv-daily-lanes-key-" + hashlib.sha256(os.urandom(16)).hexdigest()
    if len(key) < 16:
        key = key + "padding-value"
    root = Path(tempfile.mkdtemp(prefix="hv-daily-"))
    home = root / "home"
    runner = root / "runner"
    work = root / "work"
    home.mkdir()
    runner.mkdir()
    work.mkdir()
    env = base_env(home, runner, work, key)
    results = {}
    measures = {}
    results["1"] = lane1(env, work)
    measures["daily_fake_head_s"] = results["1"]["duration_s"]
    results["2"] = lane2(env, work)
    results["3"] = lane3(base_env(home, runner, work, key), work)
    results["4"] = lane4(base_env(home, runner, work, key), work, home)
    results["5"] = lane5(base_env(home, runner, work, key), work)
    results["6"] = lane6(base_env(home, runner, work, key), work)
    results["7"] = lane7(base_env(home, runner, work, key), work)
    results["8"] = lane8(base_env(home, runner, work, key), runner)
    results["9"] = lane9(base_env(home, runner, work, key), runner)
    results["10"] = lane10(base_env(home, runner, work, key), work, key)
    payload = {
        "lanes": [
            {"id": i, "name": name, "title": title, **results[i]}
            for i, name, title in LANES
        ],
        "measures": measures,
        "fingerprints": script_fingerprints(),
        "note": "PNG HD-16 non produits (aucune UI). Comparaison trunk/head et daily orb : vérificateur sur macOS.",
    }
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    sys.stdout.write(text)
    if out_path is not None:
        out_path.write_text(text, encoding="utf-8")
    failed = [row for row in payload["lanes"] if row["pass"] is False]
    shutil.rmtree(root, ignore_errors=True)
    return 10 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
