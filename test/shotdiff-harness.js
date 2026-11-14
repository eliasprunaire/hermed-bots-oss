"use strict";

const { spawnSync } = require("node:child_process");
const {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { crc32, deflateSync } = require("node:zlib");

const ROOT = join(__dirname, "..");
const SHOTDIFF = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-shotdiff.sh");
const BASELINES = join(ROOT, ".cursor/skills/verify-hermed-bots/baselines");
const HD09_HISTORIC = join(ROOT, "test/fixtures/shotdiff/hd09-cancelled-c4138edb.png");

function pngChunk(tag, data) {
  const payload = Buffer.concat([Buffer.from(tag), data]);
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(payload) >>> 0);
  return Buffer.concat([len, payload, crc]);
}

function encodePng(w, h, bit, colorType, raw, extraChunks = []) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = bit;
  ihdr[9] = colorType;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", ihdr),
    ...extraChunks,
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function encodePngRgb(w, h, rgb) {
  const stride = w * 3;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[(stride + 1) * y] = 0;
    rgb.copy(raw, (stride + 1) * y + 1, y * stride, (y + 1) * stride);
  }
  return encodePng(w, h, 8, 2, raw);
}

function encodePngRgb16(w, h, rgb) {
  const stride = w * 6;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[(stride + 1) * y] = 0;
    for (let x = 0; x < w; x++) {
      const s = (y * w + x) * 3;
      const d = (stride + 1) * y + 1 + x * 6;
      for (let c = 0; c < 3; c++) {
        const v16 = rgb[s + c] * 257;
        raw[d + c * 2] = v16 >> 8;
        raw[d + c * 2 + 1] = v16 & 255;
      }
    }
  }
  return encodePng(w, h, 16, 2, raw);
}

function encodePngRgba(w, h, rgba) {
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[(stride + 1) * y] = 0;
    rgba.copy(raw, (stride + 1) * y + 1, y * stride, (y + 1) * stride);
  }
  return encodePng(w, h, 8, 6, raw);
}

function rgbCanvas(w, h, color) {
  const buf = Buffer.alloc(w * h * 3);
  for (let i = 0; i < w * h; i++) {
    buf[i * 3] = color[0];
    buf[i * 3 + 1] = color[1];
    buf[i * 3 + 2] = color[2];
  }
  return buf;
}

function blitRgb(buf, w, x0, y0, ww, hh, color) {
  for (let y = y0; y < y0 + hh; y++) {
    for (let x = x0; x < x0 + ww; x++) {
      const o = (y * w + x) * 3;
      buf[o] = color[0];
      buf[o + 1] = color[1];
      buf[o + 2] = color[2];
    }
  }
}

function fillCircleAa(buf, w, h, cx, cy, r, color, bg) {
  const r2 = r * r;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let acc = 0;
      for (let i = 0; i < 4; i++) {
        for (let j = 0; j < 4; j++) {
          const px = x + (i + 0.5) / 4;
          const py = y + (j + 0.5) / 4;
          if ((px - cx) * (px - cx) + (py - cy) * (py - cy) <= r2) acc += 1;
        }
      }
      const t = acc / 16;
      const o = (y * w + x) * 3;
      buf[o] = Math.round(bg[0] * (1 - t) + color[0] * t);
      buf[o + 1] = Math.round(bg[1] * (1 - t) + color[1] * t);
      buf[o + 2] = Math.round(bg[2] * (1 - t) + color[2] * t);
    }
  }
}

function shotdiffIhdrEnv(dir, ae, extra = {}) {
  const bin = join(dir, "bin");
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, "compare"), `#!/bin/sh\nprintf '%s\\n' "${ae}" >&2\nexit 1\n`, { mode: 0o755 });
  writeFileSync(
    join(bin, "identify"),
    [
      "#!/bin/sh",
      "fmt=; file=",
      "while [ $# -gt 0 ]; do",
      '  case "$1" in',
      "    -format) fmt=$2; shift 2 ;;",
      "    *) file=$1; shift ;;",
      "  esac",
      "done",
      'set -- $(od -An -t u1 -j 16 -N 8 "$file")',
      "w=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))",
      "h=$(( $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 ))",
      'case "$fmt" in',
      '  %w) printf "%s\\n" "$w" ;;',
      '  %h) printf "%s\\n" "$h" ;;',
      "  *) printf '%s\\n' $((w * h)) ;;",
      "esac",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  return { ...process.env, ...extra, PATH: `${bin}:${process.env.PATH || ""}`, LC_ALL: "C" };
}

function parseZone(stdout) {
  const zone = /zone=(\d+),(\d+),(\d+)x(\d+)/.exec(stdout);
  if (!zone) return null;
  return `${zone[1]},${zone[2]},${zone[3]}x${zone[4]}`;
}

function runShotdiff(script, cap, base, dif, env, tol) {
  const args = [script, cap, base, dif];
  if (tol !== undefined) args.push(tol);
  return spawnSync("bash", args, { encoding: "utf8", env, timeout: 120000 });
}

function writePair(dir, name, baseBuf, capBuf) {
  const cap = join(dir, "cap");
  const base = join(dir, "base");
  const dif = join(dir, "dif");
  mkdirSync(cap, { recursive: true });
  mkdirSync(base, { recursive: true });
  mkdirSync(dif, { recursive: true });
  writeFileSync(join(base, name), baseBuf);
  writeFileSync(join(cap, name), capBuf);
  return { cap, base, dif, name };
}

function equivalenceCases() {
  const bg = [240, 240, 240];
  const cases = [];

  {
    const rgb = rgbCanvas(80, 60, [40, 80, 120]);
    cases.push({
      id: "identical",
      ae: "0",
      name: "ident.png",
      base: encodePngRgb(80, 60, rgb),
      cap: encodePngRgb(80, 60, rgb),
    });
  }

  {
    const a = rgbCanvas(200, 200, bg);
    const b = Buffer.from(a);
    b[0] = 10;
    b[1] = 10;
    b[2] = 10;
    b[3] = 20;
    b[4] = 20;
    b[5] = 20;
    cases.push({
      id: "noise-2px",
      ae: "2",
      name: "noise.png",
      base: encodePngRgb(200, 200, a),
      cap: encodePngRgb(200, 200, b),
    });
  }

  {
    const a = rgbCanvas(200, 200, bg);
    const b = rgbCanvas(200, 200, bg);
    blitRgb(a, 200, 90, 90, 20, 20, [255, 141, 40]);
    blitRgb(b, 200, 90, 90, 20, 20, [121, 121, 121]);
    cases.push({
      id: "frank-local",
      ae: "400",
      name: "pill.png",
      base: encodePngRgb(200, 200, a),
      cap: encodePngRgb(200, 200, b),
    });
  }

  {
    const a = rgbCanvas(200, 200, bg);
    const b = Buffer.from(a);
    let n = 0;
    for (let y = 4; y < 200; y += 28) {
      for (let x = 4; x < 200; x += 28) {
        const o = (y * 200 + x) * 3;
        b[o] = 0;
        b[o + 1] = 0;
        b[o + 2] = 0;
        n += 1;
      }
    }
    cases.push({
      id: "diffuse-under-tol",
      ae: String(n),
      name: "diffuse.png",
      base: encodePngRgb(200, 200, a),
      cap: encodePngRgb(200, 200, b),
    });
  }

  {
    const a = rgbCanvas(200, 200, bg);
    const b = rgbCanvas(200, 200, bg);
    fillCircleAa(a, 200, 200, 100.0, 100.0, 40.0, [20, 20, 20], bg);
    fillCircleAa(b, 200, 200, 100.4, 100.0, 40.0, [20, 20, 20], bg);
    cases.push({
      id: "antialias",
      ae: "298",
      name: "edge.png",
      base: encodePngRgb(200, 200, a),
      cap: encodePngRgb(200, 200, b),
    });
  }

  {
    const w = 40;
    const h = 30;
    const rgb = rgbCanvas(w, h, [40, 80, 120]);
    blitRgb(rgb, w, 10, 8, 12, 10, [200, 30, 30]);
    cases.push({
      id: "depth16-lossless",
      ae: "1",
      name: "depth.png",
      base: encodePngRgb(w, h, rgb),
      cap: encodePngRgb16(w, h, rgb),
    });
  }

  {
    const w = 200;
    const h = 200;
    const baseRgba = Buffer.alloc(w * h * 4);
    const capRgba = Buffer.alloc(w * h * 4);
    for (let i = 0; i < w * h; i++) {
      baseRgba[i * 4] = 240;
      baseRgba[i * 4 + 1] = 240;
      baseRgba[i * 4 + 2] = 240;
      capRgba[i * 4] = 240;
      capRgba[i * 4 + 1] = 240;
      capRgba[i * 4 + 2] = 240;
    }
    for (let y = 90; y < 110; y++) {
      for (let x = 90; x < 110; x++) {
        const o = (y * w + x) * 4;
        capRgba[o] = 255;
        capRgba[o + 1] = 141;
        capRgba[o + 2] = 40;
      }
    }
    cases.push({
      id: "transparent-rgb",
      ae: "1",
      name: "ghost.png",
      base: encodePngRgba(w, h, baseRgba),
      cap: encodePngRgba(w, h, capRgba),
    });
  }

  {
    const w = 200;
    const h = 200;
    const baseRgba = Buffer.alloc(w * h * 4, 255);
    const capRgba = Buffer.alloc(w * h * 4, 255);
    for (let y = 90; y < 110; y++) {
      for (let x = 90; x < 110; x++) {
        const o = (y * w + x) * 4;
        baseRgba[o] = 0;
        baseRgba[o + 1] = 0;
        baseRgba[o + 2] = 0;
        baseRgba[o + 3] = 255;
        capRgba[o] = 0;
        capRgba[o + 1] = 0;
        capRgba[o + 2] = 0;
        capRgba[o + 3] = 0;
      }
    }
    cases.push({
      id: "black-to-transparent",
      ae: "400",
      name: "hole.png",
      base: encodePngRgba(w, h, baseRgba),
      cap: encodePngRgba(w, h, capRgba),
    });
  }

  {
    cases.push({
      id: "hd09-cancelled-historic",
      ae: "428",
      name: "hd09-cancelled.png",
      base: readFileSync(join(BASELINES, "hd09-cancelled.png")),
      cap: readFileSync(HD09_HISTORIC),
    });
  }

  {
    const png = readFileSync(join(BASELINES, "hd09-cancelled.png"));
    cases.push({
      id: "hd09-cancelled-self",
      ae: "0",
      name: "hd09-cancelled.png",
      base: png,
      cap: png,
    });
  }

  return cases;
}

function captureCase(script, spec, parentDir) {
  const dir = mkdtempSync(join(parentDir || tmpdir(), `hv-eq-${spec.id}-`));
  const pair = writePair(dir, spec.name, spec.base, spec.cap);
  const env = shotdiffIhdrEnv(dir, spec.ae);
  const run = runShotdiff(script, pair.cap, pair.base, pair.dif, env);
  return {
    id: spec.id,
    status: run.status,
    stdout: run.stdout,
    stderr: run.stderr,
    zone: parseZone(run.stdout),
  };
}

function synthetic1280x800() {
  const w = 1280;
  const h = 800;
  const a = rgbCanvas(w, h, [240, 240, 240]);
  const b = rgbCanvas(w, h, [240, 240, 240]);
  blitRgb(a, w, 630, 390, 20, 20, [255, 141, 40]);
  blitRgb(b, w, 630, 390, 20, 20, [121, 121, 121]);
  return {
    name: "pair.png",
    ae: "400",
    base: encodePngRgb(w, h, a),
    cap: encodePngRgb(w, h, b),
  };
}

module.exports = {
  ROOT,
  SHOTDIFF,
  BASELINES,
  encodePngRgb,
  encodePngRgba,
  rgbCanvas,
  blitRgb,
  shotdiffIhdrEnv,
  parseZone,
  runShotdiff,
  writePair,
  equivalenceCases,
  captureCase,
  synthetic1280x800,
};
