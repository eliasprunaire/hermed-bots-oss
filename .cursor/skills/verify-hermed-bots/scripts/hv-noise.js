#!/usr/bin/env node
"use strict";

// hv-noise.js — mesure le bruit entre deux dossiers de captures du même SHA.
// Node plutôt que bash : JSON natif, tests `node --test` sans ImageMagick (absent
// de la CI), PNG décodés ici. Le verdict reste celui de hv-shotdiff.sh, appelé
// tel quel (aucune copie de sa logique de zone, aucune promotion).
// Usage : hv-noise.js [--json] [--tol 0.02] [--shotdiff chemin] <passe-1> <passe-2>

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const zlib = require("node:zlib");

const DEFAULT_TOL = 0.02;
const FUZZ = 0.05;
const FUZZ2 = (FUZZ * 255 * Math.sqrt(3)) ** 2;
const MAX_SHIFT = 4;
const DEFAULT_SHOTDIFF = path.join(__dirname, "hv-shotdiff.sh");

function usage() {
  return [
    "usage: hv-noise.js [--json] [--tol 0.02] [--shotdiff chemin] <passe-1> <passe-2>",
    "       hv-noise.js --help",
    "",
    "Compare deux dossiers de captures PNG prises au même SHA.",
    "Pour chaque écran présent des deux côtés :",
    "  px      pixels différents (fuzz 5 %, même seuil RGB que hv-shotdiff.sh)",
    "  dist    plus grande distance de couleur (Euclidienne RGB, fonds 0 et 255)",
    "  boîte   englobante des différences, format x,y,lxh",
    "  décal   translation 0 à 4 px qui minimise le ratio de pixels différents",
    "  shotdiff  verdict de hv-shotdiff.sh avec la tolérance de main (0.02)",
    "Les écrans présents d'un seul côté sont listés à part.",
    "Lecture seule : écritures limitées à un dossier temporaire, puis supprimé.",
    "Aucun réseau, aucune promotion de référence.",
  ].join("\n");
}

function parseArgs(argv) {
  let json = false;
  let help = false;
  let unknown = false;
  let tol = DEFAULT_TOL;
  let shotdiff = DEFAULT_SHOTDIFF;
  const positional = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--json") {
      json = true;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      help = true;
      continue;
    }
    if (arg === "--tol") {
      i += 1;
      tol = Number(argv[i]);
      continue;
    }
    if (arg === "--shotdiff") {
      i += 1;
      shotdiff = argv[i];
      continue;
    }
    if (arg.startsWith("-")) {
      unknown = true;
      continue;
    }
    positional.push(arg);
  }
  return {
    json,
    help,
    unknown,
    tol,
    shotdiff,
    dirA: positional[0],
    dirB: positional[1],
    extra: positional.length > 2,
  };
}

function to8(v, bit) {
  if (bit === 8) {
    return v;
  }
  return Math.floor((v * 255 + 32767) / 65535);
}

function trnsKey(chunk, offset, bit) {
  const v = (chunk[offset] << 8) | chunk[offset + 1];
  if (bit === 16) {
    return v;
  }
  return v & ((1 << bit) - 1);
}

function parsePng(buf) {
  if (
    buf.length < 8 ||
    buf[0] !== 0x89 ||
    buf[1] !== 0x50 ||
    buf[2] !== 0x4e ||
    buf[3] !== 0x47
  ) {
    throw new Error("not png");
  }
  let i = 8;
  let w;
  let h;
  let bit;
  let ct;
  let inter;
  const idat = [];
  let plte = null;
  let trns = null;
  while (i + 12 <= buf.length) {
    const ln = buf.readUInt32BE(i);
    const tag = buf.toString("ascii", i + 4, i + 8);
    const end = i + 8 + ln;
    if (end + 4 > buf.length) {
      throw new Error("png");
    }
    const chunk = buf.subarray(i + 8, end);
    if (tag === "IHDR") {
      w = chunk.readUInt32BE(0);
      h = chunk.readUInt32BE(4);
      bit = chunk[8];
      ct = chunk[9];
      inter = chunk[12];
    } else if (tag === "PLTE") {
      plte = chunk;
    } else if (tag === "tRNS") {
      trns = chunk;
    } else if (tag === "IDAT") {
      idat.push(chunk);
    } else if (tag === "IEND") {
      break;
    }
    i += 12 + ln;
  }
  if (
    w == null ||
    (bit !== 8 && bit !== 16) ||
    inter !== 0 ||
    (ct === 3 && bit === 16)
  ) {
    throw new Error("png");
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  return { w, h, bit, ct, raw, plte, trns };
}

function reconScan(scan, prev, filter, bpp) {
  const stride = scan.length;
  if (filter === 0) {
    return;
  }
  if (filter === 1) {
    for (let x = bpp; x < stride; x += 1) {
      scan[x] = (scan[x] + scan[x - bpp]) & 255;
    }
    return;
  }
  if (filter === 2) {
    for (let x = 0; x < stride; x += 1) {
      scan[x] = (scan[x] + prev[x]) & 255;
    }
    return;
  }
  if (filter === 3) {
    for (let x = 0; x < bpp; x += 1) {
      scan[x] = (scan[x] + Math.floor(prev[x] / 2)) & 255;
    }
    for (let x = bpp; x < stride; x += 1) {
      scan[x] = (scan[x] + Math.floor((scan[x - bpp] + prev[x]) / 2)) & 255;
    }
    return;
  }
  if (filter === 4) {
    for (let x = 0; x < bpp; x += 1) {
      scan[x] = (scan[x] + prev[x]) & 255;
    }
    for (let x = bpp; x < stride; x += 1) {
      const a = scan[x - bpp];
      const b = prev[x];
      const c = prev[x - bpp];
      const p = a + b - c;
      const pa = Math.abs(p - a);
      const pb = Math.abs(p - b);
      const pc = Math.abs(p - c);
      let pr = c;
      if (pa <= pb && pa <= pc) {
        pr = a;
      } else if (pb <= pc) {
        pr = b;
      }
      scan[x] = (scan[x] + pr) & 255;
    }
    return;
  }
  throw new Error("filter");
}

function samplesToRgba(scan, w, bit, ct, plte, trns) {
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[ct];
  const out = Buffer.alloc(w * 4);
  let oi = 0;
  let sp = 0;
  for (let x = 0; x < w; x += 1) {
    const native = [];
    for (let c = 0; c < channels; c += 1) {
      if (bit === 8) {
        native.push(scan[sp]);
        sp += 1;
      } else {
        native.push((scan[sp] << 8) | scan[sp + 1]);
        sp += 2;
      }
    }
    const samp = native.map((v) => to8(v, bit));
    let r;
    let g;
    let b;
    let a = 255;
    if (ct === 2) {
      r = samp[0];
      g = samp[1];
      b = samp[2];
      if (trns && trns.length >= 6) {
        const key = [
          trnsKey(trns, 0, bit),
          trnsKey(trns, 2, bit),
          trnsKey(trns, 4, bit),
        ];
        if (native[0] === key[0] && native[1] === key[1] && native[2] === key[2]) {
          a = 0;
        }
      }
    } else if (ct === 6) {
      r = samp[0];
      g = samp[1];
      b = samp[2];
      a = samp[3];
    } else if (ct === 0) {
      r = g = b = samp[0];
      if (trns && trns.length >= 2 && native[0] === trnsKey(trns, 0, bit)) {
        a = 0;
      }
    } else if (ct === 4) {
      r = g = b = samp[0];
      a = samp[1];
    } else if (ct === 3) {
      if (!plte) {
        throw new Error("plte");
      }
      const p = samp[0] * 3;
      r = plte[p];
      g = plte[p + 1];
      b = plte[p + 2];
      a = trns && native[0] < trns.length ? trns[native[0]] : 255;
    } else {
      throw new Error("png");
    }
    out[oi] = r;
    out[oi + 1] = g;
    out[oi + 2] = b;
    out[oi + 3] = a;
    oi += 4;
  }
  return out;
}

function rasterize(parsed) {
  const { w, h, bit, ct, raw, plte, trns } = parsed;
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[ct];
  const bpp = Math.max(1, channels * (bit / 8));
  const stride = w * bpp;
  const out = Buffer.alloc(w * h * 4);
  let prev = Buffer.alloc(stride);
  let pos = 0;
  let oi = 0;
  for (let y = 0; y < h; y += 1) {
    const filter = raw[pos];
    pos += 1;
    const scan = Buffer.from(raw.subarray(pos, pos + stride));
    pos += stride;
    reconScan(scan, prev, filter, bpp);
    const row = samplesToRgba(scan, w, bit, ct, plte, trns);
    row.copy(out, oi);
    oi += w * 4;
    prev = scan;
  }
  return { w, h, rgba: out };
}

function decodePngFile(file) {
  return rasterize(parsePng(fs.readFileSync(file)));
}

function over(c, bg) {
  const a = c[3];
  const inv = 255 - a;
  return [
    Math.floor((c[0] * a + bg * inv) / 255),
    Math.floor((c[1] * a + bg * inv) / 255),
    Math.floor((c[2] * a + bg * inv) / 255),
  ];
}

function pixelDist(c1, c2) {
  let maxd = 0;
  for (const bg of [0, 255]) {
    const p1 = over(c1, bg);
    const p2 = over(c2, bg);
    const dr = p1[0] - p2[0];
    const dg = p1[1] - p2[1];
    const db = p1[2] - p2[2];
    const d = Math.sqrt(dr * dr + dg * dg + db * db);
    if (d > maxd) {
      maxd = d;
    }
  }
  return maxd;
}

function visDiff(c1, c2) {
  const d = pixelDist(c1, c2);
  return d * d > FUZZ2;
}

function rgbaAt(buf, w, x, y) {
  const o = (y * w + x) * 4;
  return buf.subarray(o, o + 4);
}

function shiftedStats(a, b, w, h, dx, dy) {
  let n = 0;
  let tot = 0;
  for (let y = 0; y < h; y += 1) {
    const sy = y + dy;
    if (sy < 0 || sy >= h) {
      continue;
    }
    for (let x = 0; x < w; x += 1) {
      const sx = x + dx;
      if (sx < 0 || sx >= w) {
        continue;
      }
      tot += 1;
      if (visDiff(rgbaAt(a, w, x, y), rgbaAt(b, w, sx, sy))) {
        n += 1;
      }
    }
  }
  return { n, tot, ratio: tot === 0 ? 1 : n / tot };
}

function measureRasters(a, b, w, h) {
  let px = 0;
  let dist = 0;
  let minX = w;
  let minY = h;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      const d = pixelDist(rgbaAt(a, w, x, y), rgbaAt(b, w, x, y));
      if (d > dist) {
        dist = d;
      }
      if (d * d > FUZZ2) {
        px += 1;
        if (x < minX) {
          minX = x;
        }
        if (y < minY) {
          minY = y;
        }
        if (x > maxX) {
          maxX = x;
        }
        if (y > maxY) {
          maxY = y;
        }
      }
    }
  }
  const bbox =
    maxX < 0 ? null : `${minX},${minY},${maxX - minX + 1}x${maxY - minY + 1}`;
  let bestRatio = px / (w * h);
  let bestShift = 0;
  let bestDx = 0;
  let bestDy = 0;
  if (px > 0) {
    for (let dy = -MAX_SHIFT; dy <= MAX_SHIFT; dy += 1) {
      for (let dx = -MAX_SHIFT; dx <= MAX_SHIFT; dx += 1) {
        if (dx === 0 && dy === 0) {
          continue;
        }
        const st = shiftedStats(a, b, w, h, dx, dy);
        const mag = Math.max(Math.abs(dx), Math.abs(dy));
        const betterRatio = st.ratio < bestRatio - 1e-12;
        const sameRatio = Math.abs(st.ratio - bestRatio) <= 1e-12;
        if (betterRatio || (sameRatio && mag < bestShift)) {
          bestRatio = st.ratio;
          bestShift = mag;
          bestDx = dx;
          bestDy = dy;
        }
      }
    }
  }
  return {
    px,
    dist,
    bbox,
    shift: bestShift,
    dx: bestDx,
    dy: bestDy,
  };
}

function measurePair(fileA, fileB) {
  const imgA = decodePngFile(fileA);
  const imgB = decodePngFile(fileB);
  if (imgA.w !== imgB.w || imgA.h !== imgB.h) {
    return {
      px: null,
      dist: null,
      bbox: null,
      shift: null,
      dx: null,
      dy: null,
      sizeA: `${imgA.w}x${imgA.h}`,
      sizeB: `${imgB.w}x${imgB.h}`,
    };
  }
  return measureRasters(imgA.rgba, imgB.rgba, imgA.w, imgA.h);
}

function listPngs(dir) {
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) {
    return [];
  }
  return fs
    .readdirSync(dir)
    .filter((name) => name.endsWith(".png") && fs.statSync(path.join(dir, name)).isFile())
    .sort();
}

function classifyNames(namesA, namesB) {
  const setB = new Set(namesB);
  const setA = new Set(namesA);
  return {
    both: namesA.filter((n) => setB.has(n)),
    only1: namesA.filter((n) => !setB.has(n)),
    only2: namesB.filter((n) => !setA.has(n)),
  };
}

function parseShotdiffStdout(stdout) {
  const out = {};
  for (const line of String(stdout || "").split("\n")) {
    const m = /^(OK|DIFF|MISSING)\s+(\S+)/.exec(line);
    if (m) {
      out[m[2]] = m[1];
    }
  }
  return out;
}

function shotdiffVerdicts(shotdiff, names, dirA, dirB, tol, env) {
  if (names.length === 0) {
    return { status: 0, verdicts: {} };
  }
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), "hv-noise-"));
  try {
    const cap = path.join(parent, "cap");
    const base = path.join(parent, "base");
    const dif = path.join(parent, "dif");
    fs.mkdirSync(cap);
    fs.mkdirSync(base);
    fs.mkdirSync(dif);
    for (const name of names) {
      fs.symlinkSync(path.resolve(dirA, name), path.join(cap, name));
      fs.symlinkSync(path.resolve(dirB, name), path.join(base, name));
    }
    const run = spawnSync("bash", [shotdiff, cap, base, dif, String(tol)], {
      encoding: "utf8",
      env: env || process.env,
    });
    return {
      status: run.status,
      error: run.error,
      stderr: run.stderr,
      verdicts: parseShotdiffStdout(run.stdout),
    };
  } finally {
    fs.rmSync(parent, { recursive: true, force: true });
  }
}

function pad(value, width) {
  const text = String(value);
  if (text.length >= width) {
    return text;
  }
  return text + " ".repeat(width - text.length);
}

function formatTable(report) {
  const lines = [];
  lines.push(
    [
      pad("écran", 16),
      pad("px", 8),
      pad("dist", 8),
      pad("boîte", 16),
      pad("décal", 6),
      "shotdiff",
    ].join(" "),
  );
  for (const row of report.screens) {
    const px = row.px == null ? "-" : String(row.px);
    const dist = row.dist == null ? "-" : row.dist.toFixed(1);
    const bbox = row.bbox == null ? "-" : row.bbox;
    const shift = row.shift == null ? "-" : String(row.shift);
    lines.push(
      [
        pad(row.name, 16),
        pad(px, 8),
        pad(dist, 8),
        pad(bbox, 16),
        pad(shift, 6),
        row.verdict,
      ].join(" "),
    );
  }
  if (report.only1.length) {
    lines.push(`Présents seulement dans passe-1 : ${report.only1.join(", ")}`);
  }
  if (report.only2.length) {
    lines.push(`Présents seulement dans passe-2 : ${report.only2.join(", ")}`);
  }
  if (report.screens.length === 0 && report.only1.length === 0 && report.only2.length === 0) {
    lines.push("Aucun PNG dans les deux dossiers.");
  }
  return `${lines.join("\n")}\n`;
}

function measureFolders(dirA, dirB, opts = {}) {
  const tol = opts.tol == null ? DEFAULT_TOL : opts.tol;
  const shotdiff = opts.shotdiff || DEFAULT_SHOTDIFF;
  const namesA = listPngs(dirA);
  const namesB = listPngs(dirB);
  const { both, only1, only2 } = classifyNames(namesA, namesB);
  const screens = both.map((name) => {
    const measured = measurePair(path.join(dirA, name), path.join(dirB, name));
    return {
      name,
      px: measured.px,
      dist: measured.dist == null ? null : Math.round(measured.dist * 10) / 10,
      bbox: measured.bbox,
      shift: measured.shift,
      dx: measured.dx,
      dy: measured.dy,
      verdict: measured.sizeA ? "DIFF" : null,
      sizeA: measured.sizeA,
      sizeB: measured.sizeB,
    };
  });
  const comparable = screens.filter((row) => row.verdict == null).map((row) => row.name);
  let shot = { status: 0, verdicts: {} };
  if (comparable.length > 0) {
    shot = shotdiffVerdicts(shotdiff, comparable, dirA, dirB, tol, opts.env);
  }
  for (const row of screens) {
    if (row.verdict == null) {
      row.verdict = shot.verdicts[row.name] || "DIFF";
    }
  }
  return {
    tolerance: tol,
    fuzz: FUZZ,
    maxShift: MAX_SHIFT,
    screens,
    only1,
    only2,
    shot,
  };
}

function main(argv = process.argv.slice(2), io = {}) {
  const stdout = io.stdout || process.stdout;
  const stderr = io.stderr || process.stderr;
  const opts = parseArgs(argv);
  if (opts.help) {
    stdout.write(`${usage()}\n`);
    return 0;
  }
  if (
    opts.unknown ||
    opts.extra ||
    opts.dirA == null ||
    opts.dirB == null ||
    Number.isNaN(opts.tol)
  ) {
    stderr.write(`${usage()}\n`);
    return 2;
  }
  const namesA = listPngs(opts.dirA);
  const namesB = listPngs(opts.dirB);
  if (namesA.length === 0 && namesB.length === 0) {
    stderr.write("SHOT FAIL (15): aucune capture PNG dans les deux dossiers\n");
    return 15;
  }
  let report;
  try {
    report = measureFolders(opts.dirA, opts.dirB, {
      tol: opts.tol,
      shotdiff: opts.shotdiff,
      env: io.env || process.env,
    });
  } catch (err) {
    stderr.write("SHOT FAIL (13): mesure impossible\n");
    return 13;
  }
  if (report.shot.error || report.shot.status === 13) {
    stderr.write("SHOT FAIL (13): hv-shotdiff.sh inexécutable ou ImageMagick absent\n");
    return 13;
  }
  if (opts.json) {
    const json = {
      tolerance: report.tolerance,
      fuzz: report.fuzz,
      maxShift: report.maxShift,
      screens: report.screens.map((row) => ({
        name: row.name,
        px: row.px,
        dist: row.dist,
        bbox: row.bbox,
        shift: row.shift,
        dx: row.dx,
        dy: row.dy,
        verdict: row.verdict,
      })),
      only1: report.only1,
      only2: report.only2,
    };
    stdout.write(`${JSON.stringify(json, null, 2)}\n`);
  } else {
    stdout.write(formatTable(report));
  }
  return 0;
}

module.exports = {
  DEFAULT_TOL,
  DEFAULT_SHOTDIFF,
  FUZZ,
  MAX_SHIFT,
  classifyNames,
  decodePngFile,
  formatTable,
  listPngs,
  main,
  measureFolders,
  measurePair,
  measureRasters,
  parseArgs,
  parseShotdiffStdout,
  pixelDist,
  usage,
  visDiff,
};

if (require.main === module) {
  process.exitCode = main();
}
