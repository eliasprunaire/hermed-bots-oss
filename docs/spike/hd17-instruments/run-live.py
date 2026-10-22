#!/usr/bin/env python3
"""Sonde sans mutation des clés existantes de hv-hermes-test, jamais écrites sur le Mac."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'evidence/hd17'
CT = 'hv-hermes-test'
PROFILES = ['default', 'cyber', 'gaming', 'ia', 'perso', 'recherches', 'sport', 'tiny', 'wikilibriste']
SK = ROOT / '.cursor/skills/verify-hermed-bots/scripts'
PROBE = Path.home() / 'hermed-bots-work/hd17-probe'
READ_KEYS = r'''
import json, os, pathlib
home = pathlib.Path(os.environ['HERMES_HOME'])
profiles = ['default', 'cyber', 'gaming', 'ia', 'perso', 'recherches', 'sport', 'tiny', 'wikilibriste']
keys = {}
for profile in profiles:
    path = (home if profile == 'default' else home / 'profiles' / profile) / '.env'
    lines = [line for line in path.read_text().splitlines() if line.startswith('API_SERVER_KEY=')]
    if len(lines) != 1:
        raise SystemExit('API key entry missing or duplicated')
    keys[profile] = lines[0].split('=', 1)[1].strip().strip('"').strip("'")
print(json.dumps(keys))
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(['bash', str(SK / 'hv-guard.sh'), 'snapshot', str(OUT / 'guard-live-before.txt')], check=True)
    subprocess.run(['bash', str(SK / 'hv-guard.sh'), 'target', CT], check=True)
    print(f'Cible {CT}: lecture des neuf clés existantes en mémoire seulement', flush=True)
    result = subprocess.run(['docker', 'exec', CT, 'python3', '-c', READ_KEYS], text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Lecture des clés impossible, sortie retenue')
    keys = json.loads(result.stdout)
    assert len(keys) == len(set(keys.values())) == 9, 'Neuf clés distinctes requises'
    package = ROOT / 'Packages/HermesAdapter'
    with (OUT / 'probe-build.log').open('w') as log:
        subprocess.run(['swift', 'build', '--package-path', str(package)], stdout=log, stderr=subprocess.STDOUT, check=True)
        products = Path(subprocess.check_output(['swift', 'build', '--package-path', str(package), '--show-bin-path'], text=True).strip())
        command = ['swiftc', '-D', 'DEBUG', '-parse-as-library', '-I', str(products), str(products / 'HermesAdapter.o')]
        command += [str(ROOT / path) for path in ['HermedBots/Secrets/SecretStore.swift', 'HermedBots/App/AppEnvironment.swift', 'HermedBots/Transport/ResumeAPI.swift', 'HermedBots/KillSwitch/KillSwitch.swift', 'docs/spike/hd17-instruments/probe.swift']]
        command += ['-o', str(PROBE)]
        print('Build de la sonde: swiftc avec SecretStore, AppEnvironment, ResumeAPI, KillSwitchAPI et HermesAdapter', flush=True)
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([str(PROBE)], input=json.dumps(keys), text=True, capture_output=True, timeout=300)
    output = result.stdout + result.stderr
    if any(k in output for k in keys.values()):
        raise RuntimeError('Secret détecté, sortie retenue')
    print(output, end='', flush=True)
    print(f'probe rc={result.returncode}', flush=True)
    subprocess.run(['bash', str(SK / 'hv-guard.sh'), 'check', str(OUT / 'guard-live-before.txt')], check=True)
    return result.returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(f'HD17 LIVE FAIL: {type(error).__name__}', file=sys.stderr)
        sys.exit(1)
