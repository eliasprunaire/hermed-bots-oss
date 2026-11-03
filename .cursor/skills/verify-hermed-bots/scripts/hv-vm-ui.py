#!/usr/bin/env python3
"""Passe UI réelle : hôte (VM + tunnel inverse) ou invité (xcodebuild). Modèle : aucun."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
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


def vm_argv(*args: str) -> list[str] | None:
    vm = vm_sh()
    if vm is None or not vm.is_file():
        return None
    zsh = shutil.which("zsh")
    return ([zsh, str(vm)] if zsh else [str(vm)]) + list(args)


def guard_target(host: str) -> int:
    guard = HERE / "hv-guard.sh"
    proc = subprocess.run(["bash", str(guard), "target", host], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 22 if proc.returncode == 22 else proc.returncode


def load_ui_secrets() -> tuple[str, str]:
    """Lit les clés hors dépôt (hv-bot-a/b) et complète les profils fixtures pour la lane fake.

    Ne les imprime jamais. Les deux clés issue56 restent celles du fichier privé ; les
    autres profils `served` reçoivent une clé déterministe dérivée du nom (HD17).
    """
    work = Path(os.environ.get("HV_WORK") or (Path.home() / "hermed-bots-work"))
    path = Path(os.environ.get("HV_UI_KEYS_FILE") or (work / "secrets" / "hv-ui-keys.json"))
    raw_env = os.environ.get("HV_TEST_API_KEYS")
    if raw_env:
        keys = json.loads(raw_env)
    else:
        keys = json.loads(path.read_text(encoding="utf-8"))
    if not {"hv-bot-a", "hv-bot-b"}.issubset(set(keys)):
        raise ValueError("hv-ui-keys.json doit porter au moins hv-bot-a et hv-bot-b")
    fixtures = HERE / ".." / "fixtures" / "hermes-current" / "contract.json"
    try:
        served = json.loads(fixtures.read_text(encoding="utf-8"))["profiles"]["served"]
    except (OSError, KeyError, json.JSONDecodeError, TypeError):
        served = ["hv-bot-a", "hv-bot-b"]
    import hashlib
    for name in served:
        if name not in keys:
            # 64 hex chars, stable across runs, distinct per profile (HD17 crossed-key).
            keys[name] = hashlib.sha256(("hv-ui-fixture:" + name).encode()).hexdigest()
    # Table courte issue56 (layout ProfileTable.parse). Défaut multiligne OK en env local
    # (guest()); via `env KEY=value` ssh (host) les retours à la ligne cassent — host()
    # n'exporte que si la table est mono-ligne. Fake sans export → /_hv/profile-list.
    # En-tête et colonnes comme `hermes profile list` (ProfileTable.parse exige «  » et Gateway).
    # L'ancienne table compacte « Profile Model Gateway » (espaces simples) ne parsait pas → bots.error + version inconnue.
    default_table = (
        " Profile          Model                        Gateway      Alias        Distribution\n"
        " ───────────────    ───────────────────────────    ───────────    ───────────    ────────────────────\n"
        " ◆hv-bot-a        hv-fake-1                    running      —            —\n"
        "  hv-bot-b        hv-fake-1                    running      —            —\n"
    )
    table = os.environ["HV_TEST_PROFILE_TABLE"] if "HV_TEST_PROFILE_TABLE" in os.environ else default_table
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
    env["TEST_RUNNER_HV_TEST_MODE"] = "1"
    env["TEST_RUNNER_HV_TEST_API_KEYS"] = packed
    if table:
        env["HV_TEST_PROFILE_TABLE"] = table
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


def reverse_tunnel_spec(port: str) -> str:
    return "127.0.0.1:%s:127.0.0.1:%s" % (port, port)


def install_ssh_reverse_wrapper(port: str) -> Path:
    """Injecte -R sur le transport SSH de vm.sh (même VM que build + tests).

    vm.sh remet PATH avec /usr/bin avant tout shim, et la passe longue est
    « timeout N ssh … » (execvp ignore une fonction ssh). On pose donc un
    binaire shim + ZDOTDIR/.zshenv qui redéfinit timeout() pour y substituer
    le shim portant -R / ExitOnForwardFailure.
    """
    d = Path(tempfile.mkdtemp(prefix="hv-ssh-r-"))
    spec = reverse_tunnel_spec(port)
    wrapper = d / "ssh"
    # Ne pas passer -N/-R comme argv invité de « vm.sh exec » : le shim les pose sur /usr/bin/ssh.
    wrapper.write_text(
        "#!/bin/sh\n"
        "exec /usr/bin/ssh -o ExitOnForwardFailure=yes -R %s \"$@\"\n" % spec,
        encoding="utf-8",
    )
    wrapper.chmod(0o755)
    zdot = d / "zdot"
    zdot.mkdir()
    # Fonctions zsh : survivent au « export PATH=.../usr/bin:... » de vm.sh.
    # Ne PAS poser -R sur chaque ssh : les appels courts de setup se chevauchent
    # et ExitOnForwardFailure coupe la session (port 18642 déjà pris).
    # vm.sh lance la passe longue via « timeout N ssh … » ; timeout(1) fait
    # execvp("ssh") et ignore une fonction ssh — on réécrit l'argv vers le shim.
    wrap = str(wrapper)
    (zdot / ".zshenv").write_text(
        "timeout() {\n"
        "  local -a a\n"
        "  local x\n"
        "  for x in \"$@\"; do\n"
        "    if [[ \"$x\" == ssh || \"$x\" == */ssh ]]; then\n"
        "      a+=(%s)\n"
        "    else\n"
        "      a+=(\"$x\")\n"
        "    fi\n"
        "  done\n"
        "  command timeout \"${a[@]}\"\n"
        "}\n" % (wrap,),
        encoding="utf-8",
    )
    return d


def start_reverse_tunnel(port: str) -> subprocess.Popen | None:
    """Prépare le tunnel inverse via shim PATH + un exec vm.sh qui reste vivant pour le test unitaire.

    La redirection vit sur le transport SSH, pas comme commande invitée. Pour la passe réelle,
    host() réutilise install_ssh_reverse_wrapper sur le seul vm.sh exec (build + tests).
    """
    if vm_argv("exec") is None:
        return None
    shim = install_ssh_reverse_wrapper(port)
    # Holder : garde le répertoire shim et prouve qu'un exec vm.sh reste joignable avec le PATH.
    # « true » est une commande invitée inoffensive ; -N/-R ne figurent jamais dans argv invité.
    cmd = vm_argv("exec", "sleep", "30")
    if cmd is None:
        shutil.rmtree(shim, ignore_errors=True)
        return None
    env = os.environ.copy()
    env["PATH"] = "%s:%s" % (shim, env.get("PATH", ""))
    env["ZDOTDIR"] = str(shim / "zdot")
    env["HV_SSH_REVERSE_SHIM"] = str(shim)
    try:
        return subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        shutil.rmtree(shim, ignore_errors=True)
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
    if vm_argv("exec") is None:
        log("HV-UI SAUTÉE")
        log("HV-UI chemin=attente rc=6 durée=%.0f preuves=aucune" % (time.time() - t0))
        return 6
    target = os.environ.get("HV_TARGET_HOST", "hv-hermes-test")
    if guard_target(target) == 22:
        log("cible refusée")
        return 22
    port = os.environ.get("HV_PORT", "18642")
    env = os.environ.copy()
    env.setdefault("HV_UI_BACKEND", "orb")
    backend = env.get("HV_UI_BACKEND", "orb")
    shim = None
    if backend == "orb":
        shim = install_ssh_reverse_wrapper(port)
        env["PATH"] = "%s:%s" % (shim, env.get("PATH", ""))
        env["ZDOTDIR"] = str(shim / "zdot")
    env.setdefault("HV_UNDER_RUNNER", "1")
    env.setdefault("HV_API_URL", "http://127.0.0.1:%s" % port)
    # Invité : hv-run.sh exige HV_RUNNER_DIR (set -u / :?). Chemin générique absent OK
    # (PAUSE/.lock inexistants) — pas de chemin hôte réel dans le dépôt.
    guest_runner = os.environ.get("HV_GUEST_RUNNER_DIR") or "/tmp/hv-runner"
    guest_env = [
        "HV_UI_BACKEND=%s" % backend,
        "HV_API_URL=http://127.0.0.1:%s" % port,
        "HV_UNDER_RUNNER=1",
        "HV_RUNNER_DIR=%s" % guest_runner,
    ]
    try:
        packed, table = load_ui_secrets()
        env["HV_TEST_API_KEYS"] = packed
        # Traversent l'invité via « env » sur la commande (fichier de clés hors VM).
        guest_env.append("HV_TEST_API_KEYS=%s" % packed)
        # Table vide : ne pas exporter ("" est non-nil en Swift et casse ProfileTable.parse).
        if table:
            env["HV_TEST_PROFILE_TABLE"] = table
            # ssh `env KEY=value` refuse les retours à la ligne : n'exporter que mono-ligne
            if "\n" not in table:
                guest_env.append("HV_TEST_PROFILE_TABLE=%s" % table)
    except (OSError, ValueError, json.JSONDecodeError):
        packed = None
    # Une seule VM : vm.sh fait build-for-testing, pose HV_XCTESTRUN sur le produit invité, puis la commande.
    # Ne pas chercher le .xctestrun sur l'hôte après une compilation invitée.
    cmd = vm_argv(
        "exec",
        "env",
        *guest_env,
        "bash",
        ".cursor/skills/verify-hermed-bots/scripts/hv-run.sh",
        "ui",
        "fake",
    )
    try:
        proc = subprocess.run(cmd, env=env)
        rc = proc.returncode
    finally:
        if shim is not None:
            shutil.rmtree(shim, ignore_errors=True)
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
