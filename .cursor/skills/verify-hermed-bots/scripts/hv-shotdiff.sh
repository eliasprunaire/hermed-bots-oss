#!/usr/bin/env bash
# hv-shotdiff.sh — compare les captures d'une passe aux références. Modèle : aucun.
# Usage : hv-shotdiff.sh <dossier-captures> <dossier-baselines> <dossier-diffs> [tolérance=0.02]
#         hv-shotdiff.sh --export <xcresult> <dossier-captures> [nom-attendu...]   # pièces jointes PNG -> <nom>.png
#         hv-shotdiff.sh --bless <dossier-captures> <dossier-baselines>   # promeut (humain seulement)
# Tolérance = fraction de pixels différents (fuzz 5 % par pixel). Outil : ImageMagick `compare`
# (brew install imagemagick). Un écart franc localisé (zone connexe après érosion d'un pixel,
# ΔE élevé) échoue aussi, même si le ratio global reste sous la tolérance. Codes : 0 OK ; 2 usage ;
# 11 écart > tolérance ou zone locale ; 12 baseline manquante ; 13 outil absent ; 15 captures
# absentes (dossier absent ou sans PNG, export impossible, nom attendu manquant).
# Le runner XCUITest est sandboxé : il n'écrit pas dans le dossier des captures, qui vient de --export.
# Le jugement visuel final reste manuel (A3) : ce script ne fait que trier.
set -euo pipefail
if [ "${1:-}" = --bless ]; then
  [ $# -eq 3 ] || { echo "usage: $0 --bless <captures> <baselines>" >&2; exit 2; }
  mkdir -p "$3"; cp -v "$2"/*.png "$3"/; exit 0
fi
if [ "${1:-}" = --export ]; then
  [ $# -ge 3 ] || { echo "usage: $0 --export <xcresult> <captures> [nom-attendu...]" >&2; exit 2; }
  RES=$2; CAP=$3; shift 3
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  xcrun xcresulttool export attachments --path "$RES" --output-path "$TMP" --filter '*.png' > "$TMP/export.log" 2>&1 \
    || { echo "SHOT FAIL (15): export des pièces jointes de $RES impossible : $(tail -2 "$TMP/export.log")" >&2; exit 15; }
  mkdir -p "$CAP"
  # une pièce jointe se nomme <nom>_<n>_<UUID>.png : on garde <nom> ; pas de exec, pour que le trap nettoie $TMP
  python3 -I - "$TMP" "$CAP" "$@" <<'PY'
import json, os, re, shutil, sys
tmp, cap, expected = sys.argv[1], sys.argv[2], sys.argv[3:]
got = set()
for test in json.load(open(os.path.join(tmp, "manifest.json"), encoding="utf-8")):
    for a in test["attachments"]:
        human = a["suggestedHumanReadableName"]
        if not human.endswith(".png"):
            continue
        m = re.fullmatch(r"(.*?)_\d+_[0-9A-Za-z-]+\.png", human)
        name = m.group(1) if m else human.removesuffix(".png")
        shutil.copyfile(os.path.join(tmp, a["exportedFileName"]), os.path.join(cap, name + ".png"))
        got.add(name)
missing = [n for n in expected if n not in got]
if missing or not got:
    print("SHOT FAIL (15): " + ("capture attendue absente du xcresult : " + ", ".join(missing) if missing else "aucune capture dans le xcresult"), file=sys.stderr)
    sys.exit(15)
print("EXPORT OK %d capture(s) : %s" % (len(got), ", ".join(sorted(got))))
PY
  exit $?
fi
[ $# -ge 3 ] || { echo "usage: $0 <captures> <baselines> <diffs> [tol]" >&2; exit 2; }
CAP=$1; BASE=$2; DIF=$3; TOL=${4:-0.02}
compgen -G "$CAP/*.png" >/dev/null || { echo "SHOT FAIL (15): aucune capture dans $CAP" >&2; exit 15; }
command -v compare >/dev/null 2>&1 || { echo "SHOT FAIL (13): ImageMagick 'compare' absent" >&2; exit 13; }
mkdir -p "$DIF"; rc=0
# Locale C : compare/identify/awk doivent produire un point décimal (fr_FR sinon → virgule → faux OK).
export LC_ALL=C
export LC_NUMERIC=C
for f in "$CAP"/*.png; do
  [ -e "$f" ] || continue
  n=$(basename "$f")
  if [ ! -f "$BASE/$n" ]; then echo "MISSING $n"; [ $rc -eq 0 ] && rc=12; continue; fi
  bw=$(identify -format '%w' "$BASE/$n"); bw=$(printf '%s' "$bw" | tr ',' '.')
  bh=$(identify -format '%h' "$BASE/$n"); bh=$(printf '%s' "$bh" | tr ',' '.')
  cw=$(identify -format '%w' "$f"); cw=$(printf '%s' "$cw" | tr ',' '.')
  ch=$(identify -format '%h' "$f"); ch=$(printf '%s' "$ch" | tr ',' '.')
  if [ "$bw" != "$cw" ] || [ "$bh" != "$ch" ]; then
    echo "DIFF $n size ${cw}x${ch} != baseline ${bw}x${bh}"
    rc=11
    continue
  fi
  px=$(compare -metric AE -fuzz 5% "$BASE/$n" "$f" null: 2>&1 >/dev/null || true)
  # Normalise une éventuelle virgule décimale (locale parent) avant awk.
  px=${px%% *}
  px=$(printf '%s' "$px" | tr ',' '.')
  tot=$(identify -format '%[fx:w*h]' "$BASE/$n")
  tot=$(printf '%s' "$tot" | tr ',' '.')
  ratio=$(awk -v a="$px" -v b="$tot" 'BEGIN{ if (a !~ /^[0-9.e+]+$/) a=b; printf "%.5f", a/b }')
  if awk -v r="$ratio" -v t="$TOL" 'BEGIN{exit !(r>t)}'; then
    compare -metric AE -fuzz 5% "$BASE/$n" "$f" "$DIF/$n" >/dev/null 2>&1 || true
    echo "DIFF $n ratio=$ratio > $TOL"; rc=11; continue
  fi
  if awk -v a="$px" 'BEGIN{exit !(a+0==0)}'; then echo "OK   $n ratio=$ratio"; rm -f "$DIF/$n"; continue; fi
  if cmp -s "$BASE/$n" "$f"; then echo "OK   $n ratio=$ratio"; rm -f "$DIF/$n"; continue; fi
  command -v python3 >/dev/null 2>&1 || { echo "SHOT FAIL (13): python3 absent" >&2; [ $rc -eq 0 ] && rc=13; continue; }
  zone=$(python3 -I - "$BASE/$n" "$f" <<'PY'
import math, struct, sys, zlib

FUZZ2 = (0.05 * 255 * math.sqrt(3)) ** 2
MIN_ERODED = 80
MIN_SIDE = 8
MIN_DE = 10.0

def to8(v, bit):
    if bit == 8:
        return v
    return (v * 255 + 32767) // 65535

def trns_key(chunk, offset, bit):
    v = (chunk[offset] << 8) | chunk[offset + 1]
    if bit == 16:
        return v
    return v & ((1 << bit) - 1)

def parse_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not png")
    i = 8
    w = h = bit = ct = inter = None
    idat = []
    plte = None
    trns = None
    while i + 12 <= len(data):
        ln = struct.unpack(">I", data[i : i + 4])[0]
        tag = data[i + 4 : i + 8]
        chunk = data[i + 8 : i + 8 + ln]
        if tag == b"IHDR":
            w, h, bit, ct, _comp, _filt, inter = struct.unpack(">IIBBBBB", chunk)
        elif tag == b"PLTE":
            plte = chunk
        elif tag == b"tRNS":
            trns = chunk
        elif tag == b"IDAT":
            idat.append(chunk)
        elif tag == b"IEND":
            break
        i += 12 + ln
    if w is None or bit not in (8, 16) or inter != 0 or (ct == 3 and bit == 16):
        raise ValueError("png")
    raw = zlib.decompress(b"".join(idat))
    return w, h, bit, ct, raw, plte, trns

def recon_scan(scan, prev, f, bpp):
    stride = len(scan)
    if f == 0:
        return
    if f == 1:
        for x in range(bpp, stride):
            scan[x] = (scan[x] + scan[x - bpp]) & 255
        return
    if f == 2:
        for x in range(stride):
            scan[x] = (scan[x] + prev[x]) & 255
        return
    if f == 3:
        for x in range(bpp):
            scan[x] = (scan[x] + (prev[x] // 2)) & 255
        for x in range(bpp, stride):
            scan[x] = (scan[x] + ((scan[x - bpp] + prev[x]) // 2)) & 255
        return
    if f == 4:
        for x in range(bpp):
            scan[x] = (scan[x] + prev[x]) & 255
        for x in range(bpp, stride):
            a = scan[x - bpp]
            b = prev[x]
            c = prev[x - bpp]
            p = a + b - c
            pa = p - a
            if pa < 0:
                pa = -pa
            pb = p - b
            if pb < 0:
                pb = -pb
            pc = p - c
            if pc < 0:
                pc = -pc
            if pa <= pb and pa <= pc:
                pr = a
            elif pb <= pc:
                pr = b
            else:
                pr = c
            scan[x] = (scan[x] + pr) & 255
        return
    raise ValueError("filter")

def samples_to_rgba(scan, w, bit, ct, plte, trns):
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    out = bytearray(w * 4)
    oi = 0
    sp = 0
    for _x in range(w):
        native = []
        for _c in range(channels):
            if bit == 8:
                native.append(scan[sp])
                sp += 1
            else:
                native.append((scan[sp] << 8) | scan[sp + 1])
                sp += 2
        samp = [to8(v, bit) for v in native]
        if ct == 2:
            r, g, b = samp
            a = 255
            if trns and len(trns) >= 6:
                key = (
                    trns_key(trns, 0, bit),
                    trns_key(trns, 2, bit),
                    trns_key(trns, 4, bit),
                )
                if tuple(native) == key:
                    a = 0
        elif ct == 6:
            r, g, b, a = samp
        elif ct == 0:
            r = g = b = samp[0]
            a = 255
            if trns and len(trns) >= 2 and native[0] == trns_key(trns, 0, bit):
                a = 0
        elif ct == 4:
            r = g = b = samp[0]
            a = samp[1]
        elif ct == 3:
            if not plte:
                raise ValueError("plte")
            p = samp[0] * 3
            r, g, b = plte[p], plte[p + 1], plte[p + 2]
            a = trns[native[0]] if trns and native[0] < len(trns) else 255
        else:
            raise ValueError("png")
        out[oi] = r
        out[oi + 1] = g
        out[oi + 2] = b
        out[oi + 3] = a
        oi += 4
    return out

def rasterize(w, h, bit, ct, raw, plte, trns):
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    bpp = max(1, channels * (bit // 8))
    stride = w * bpp
    out = bytearray(w * h * 4)
    prev = bytearray(stride)
    pos = 0
    oi = 0
    fast_rgba = bit == 8 and ct == 6
    fast_rgb = bit == 8 and ct == 2 and not trns
    for _y in range(h):
        f = raw[pos]
        pos += 1
        scan = bytearray(raw[pos : pos + stride])
        pos += stride
        recon_scan(scan, prev, f, bpp)
        if fast_rgba:
            out[oi : oi + stride] = scan
            oi += stride
        elif fast_rgb:
            sp = 0
            for _x in range(w):
                out[oi] = scan[sp]
                out[oi + 1] = scan[sp + 1]
                out[oi + 2] = scan[sp + 2]
                out[oi + 3] = 255
                oi += 4
                sp += 3
        else:
            row = samples_to_rgba(scan, w, bit, ct, plte, trns)
            out[oi : oi + w * 4] = row
            oi += w * 4
        prev = scan
    return bytes(out)

def decode_rgba8_pair(raw_a, raw_b, w, h):
    bpp = 4
    stride = w * 4
    rowb = stride + 1
    out_a = bytearray(w * h * 4)
    out_b = bytearray(w * h * 4)
    prev_a = bytearray(stride)
    prev_b = bytearray(stride)
    pos = 0
    oi = 0
    same_prev = True
    equal_rows = bytearray(h)
    for y in range(h):
        fa = raw_a[pos]
        fb = raw_b[pos]
        sa = bytearray(raw_a[pos + 1 : pos + 1 + stride])
        sb = bytearray(raw_b[pos + 1 : pos + 1 + stride])
        pos += rowb
        identical = same_prev and fa == fb and sa == sb
        recon_scan(sa, prev_a, fa, bpp)
        out_a[oi : oi + stride] = sa
        if identical:
            out_b[oi : oi + stride] = sa
            prev_b = bytearray(sa)
            same_prev = True
            equal_rows[y] = 1
        else:
            recon_scan(sb, prev_b, fb, bpp)
            out_b[oi : oi + stride] = sb
            prev_b = sb
            same_prev = sa == sb
        prev_a = sa
        oi += stride
    return bytes(out_a), bytes(out_b), equal_rows

def srgb_to_lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def rgb_to_lab(r, g, b):
    r, g, b = srgb_to_lin(r), srgb_to_lin(g), srgb_to_lin(b)
    x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047
    y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
    z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else (7.787 * t + 16 / 116)

    fx, fy, fz = f(x), f(y), f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))

def over(r, g, b, a, bg):
    inv = 255 - a
    return ((r * a + bg * inv) // 255, (g * a + bg * inv) // 255, (b * a + bg * inv) // 255)

def de_rgb(c1, c2):
    L1, a1, b1 = rgb_to_lab(*c1)
    L2, a2, b2 = rgb_to_lab(*c2)
    return math.sqrt((L1 - L2) ** 2 + (a1 - a2) ** 2 + (b1 - b2) ** 2)

def mean_de(a, b, w, pts):
    acc = 0.0
    n = 0
    step = max(1, len(pts) // 400)
    for x, y in pts[::step]:
        o = (y * w + x) * 4
        c1 = a[o : o + 4]
        c2 = b[o : o + 4]
        d_black = de_rgb(over(c1[0], c1[1], c1[2], c1[3], 0), over(c2[0], c2[1], c2[2], c2[3], 0))
        d_white = de_rgb(over(c1[0], c1[1], c1[2], c1[3], 255), over(c2[0], c2[1], c2[2], c2[3], 255))
        acc += d_black if d_black > d_white else d_white
        n += 1
    return acc / n if n else 0.0

def vis_diff(c1, c2):
    for bg in (0, 255):
        p1 = over(c1[0], c1[1], c1[2], c1[3], bg)
        p2 = over(c2[0], c2[1], c2[2], c2[3], bg)
        dr, dg, db = p1[0] - p2[0], p1[1] - p2[1], p1[2] - p2[2]
        if dr * dr + dg * dg + db * db > FUZZ2:
            return True
    return False

def collect_pix(a, b, w, h, equal_rows=None):
    n = w * h
    pix = set()
    opaque = a[3::4] == b"\xff" * n and b[3::4] == b"\xff" * n
    if opaque:
        ar, ag, ab = a[0::4], a[1::4], a[2::4]
        br, bg, bb = b[0::4], b[1::4], b[2::4]
        if equal_rows is None:
            for p in range(n):
                dr = ar[p] - br[p]
                dg = ag[p] - bg[p]
                db = ab[p] - bb[p]
                if dr * dr + dg * dg + db * db > FUZZ2:
                    pix.add((p % w, p // w))
        else:
            for y in range(h):
                if equal_rows[y]:
                    continue
                base = y * w
                for x in range(w):
                    p = base + x
                    dr = ar[p] - br[p]
                    dg = ag[p] - bg[p]
                    db = ab[p] - bb[p]
                    if dr * dr + dg * dg + db * db > FUZZ2:
                        pix.add((x, y))
        return pix
    for p in range(n):
        i = p * 4
        if vis_diff(a[i : i + 4], b[i : i + 4]):
            pix.add((p % w, p // w))
    return pix

def find_zone(a, b, w, h, pix):
    if not pix:
        return 0
    visited = set()
    best = None
    for seed in pix:
        if seed in visited:
            continue
        stack = [seed]
        visited.add(seed)
        comp = []
        while stack:
            x, y = stack.pop()
            comp.append((x, y))
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    nxt = (x + dx, y + dy)
                    if nxt in pix and nxt not in visited:
                        visited.add(nxt)
                        stack.append(nxt)
        er = [
            (x, y)
            for x, y in comp
            if (x - 1, y) in pix and (x + 1, y) in pix and (x, y - 1) in pix and (x, y + 1) in pix
        ]
        if len(er) < MIN_ERODED:
            continue
        xs = [p[0] for p in er]
        ys = [p[1] for p in er]
        side = min(max(xs) - min(xs) + 1, max(ys) - min(ys) + 1)
        if side < MIN_SIDE:
            continue
        de = mean_de(a, b, w, er)
        if de < MIN_DE:
            continue
        cand = (len(er), comp, er, de)
        if best is None or cand[0] > best[0]:
            best = cand
    if best is None:
        return 0
    _eroded_n, comp, _er, de = best
    xs = [p[0] for p in comp]
    ys = [p[1] for p in comp]
    x0, y0 = min(xs), min(ys)
    bw, bh = max(xs) - x0 + 1, max(ys) - y0 + 1
    sys.stdout.write("%d,%d,%dx%d px=%d dE=%.1f\n" % (x0, y0, bw, bh, len(comp), de))
    return 1

def main(base, cap):
    wa, ha, bit_a, ct_a, raw_a, plte_a, trns_a = parse_png(base)
    wb, hb, bit_b, ct_b, raw_b, plte_b, trns_b = parse_png(cap)
    if (wa, ha) != (wb, hb):
        raise ValueError("size")
    equal_rows = None
    if (
        bit_a == 8
        and bit_b == 8
        and ct_a == 6
        and ct_b == 6
        and not trns_a
        and not trns_b
    ):
        a, b, equal_rows = decode_rgba8_pair(raw_a, raw_b, wa, ha)
    else:
        a = rasterize(wa, ha, bit_a, ct_a, raw_a, plte_a, trns_a)
        b = rasterize(wb, hb, bit_b, ct_b, raw_b, plte_b, trns_b)
    pix = collect_pix(a, b, wa, ha, equal_rows)
    return find_zone(a, b, wa, ha, pix)

try:
    sys.exit(main(sys.argv[1], sys.argv[2]))
except Exception as exc:
    sys.stderr.write("analyse locale: %s\n" % exc)
    sys.exit(2)
PY
) && zrc=0 || zrc=$?
  if [ "$zrc" -eq 0 ]; then echo "OK   $n ratio=$ratio"; rm -f "$DIF/$n"
  elif [ "$zrc" -eq 1 ]; then
    compare -metric AE -fuzz 5% "$BASE/$n" "$f" "$DIF/$n" >/dev/null 2>&1 || true
    echo "DIFF $n ratio=$ratio zone=$zone"; rc=11
  else echo "SHOT FAIL (13): analyse locale impossible pour $n" >&2; [ $rc -eq 0 ] && rc=13; fi
done
exit $rc
