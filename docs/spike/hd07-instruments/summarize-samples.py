#!/usr/bin/env python3
"""summarize-samples.py <ps-samples.txt> : résume l'échantillonnage des processus du tunnel
Chaque ligne : `<t> TICK` (une par passage de l'échantillonneur) ou `<t> <pgid> <pid> <ppid> <arguments>` (un processus vu)
Un groupe est « vivant à la fin » s'il figure dans le dernier échantillon, après lequel l'app était fermée"""
import collections
import sys

ticks, seen = [], collections.defaultdict(list)
for line in open(sys.argv[1], errors="replace"):
    parts = line.split(None, 4)
    if len(parts) == 2 and parts[1].strip() == "TICK":
        ticks.append(float(parts[0]))
    elif len(parts) >= 5:
        seen[int(parts[1])].append((float(parts[0]), int(parts[2]), int(parts[3]), parts[4].strip()))

if not ticks:
    print("RESULT FAIL: aucun échantillon")
    sys.exit(2)
last_tick = ticks[-1]


def role(args):
    if "ssh-agent" in args:
        return "ssh-agent"
    if "while read" in args:
        return "gardien (sh)"
    if args.startswith("/usr/bin/ssh "):
        return "ssh"
    return args.split()[0]


print("échantillons : %d, du début à la fin %.1f s" % (len(ticks), last_tick - ticks[0]))
survivors = 0
for pgid, rows in sorted(seen.items(), key=lambda kv: kv[1][0][0]):
    first, last = rows[0][0], rows[-1][0]
    roles = sorted({role(a) for _, _, _, a in rows})
    pids = sorted({pid for _, pid, _, _ in rows})
    alive = last >= last_tick - 0.01
    survivors += alive
    print("groupe %d : vu de t+%.1f s à t+%.1f s, %d processus (%s) : %s" % (pgid, first - ticks[0], last - ticks[0], len(pids), ", ".join(roles), "ENCORE VIVANT au dernier échantillon" if alive else "disparu"))
if not seen:
    print("aucun processus de tunnel vu pendant la passe")
print("RESULT %s : %d groupe(s) vu(s), %d vivant(s) à la fin" % ("OK" if survivors == 0 else "FAIL", len(seen), survivors))
sys.exit(1 if survivors else 0)
