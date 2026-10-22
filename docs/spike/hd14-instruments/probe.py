import json
import os
from pathlib import Path
import psutil

held = set()
for process in psutil.process_iter():
    try:
        if process.uids().real != os.getuid():
            continue
        args = process.cmdline()
        if 'serve' not in args:
            continue
        env = process.environ()
        if env.get('HERMES_DESKTOP') != '1':
            continue
        home = Path(env.get('HERMES_HOME') or Path.home() / '.hermes').resolve()
        profile = home.name if home.parent.name == 'profiles' else 'default'
        for flag in ('--profile', '-p'):
            if flag in args[:args.index('serve')]:
                profile = args[args.index(flag) + 1]
        held.add(profile)
        for opened in process.open_files():
            path = Path(opened.path)
            if path.name in ('state.db', 'state.db-wal', 'state.db-shm') and path.parent.parent.name == 'profiles':
                held.add(path.parent.name)
    except psutil.NoSuchProcess:
        continue
print(json.dumps({'held': sorted(held)}))
