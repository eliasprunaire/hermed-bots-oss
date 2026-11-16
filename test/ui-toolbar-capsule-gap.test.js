"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { inflateSync } = require("node:zlib");
const { blitRgb, encodePngRgb, rgbCanvas } = require("./shotdiff-harness.js");

const ROOT = join(__dirname, "..");
const APPEARANCES = ["light", "dark"];
const SIZES = ["standard", "large"];
const GAP_SOURCE = "Packages/HermesAdapter/Sources/AppSettings/ToolbarCapsuleGap.swift";
const SCAN_Y = 52;
const TARGET_FREE_PX = 26;
const OLD_FREE_PX = 14;

function read(rel) {
  return readFileSync(join(ROOT, rel), "utf8");
}

function firstBlock(source, marker) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, marker);
  const open = source.indexOf("{", start);
  assert.notEqual(open, -1, marker);
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    const char = source[index];
    if (char === "{") depth += 1;
    else if (char === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  assert.fail(marker);
}

function matchingParen(source, open) {
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    const char = source[index];
    if (char === "(") depth += 1;
    else if (char === ")") {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

function staticDouble(source, name) {
  const match = new RegExp(String.raw`static let ${name} = ([-\d.]+)`).exec(source);
  assert.notEqual(match, null, name);
  return Number(match[1]);
}

function functionBody(source, name) {
  const marker = `func ${name}(`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, name);
  return firstBlock(source.slice(start), marker).replace(/^[^{]*\{/, "").replace(/\}$/, "").trim();
}

function stripOuterParens(expr) {
  let text = expr.trim();
  while (text.startsWith("(")) {
    const close = matchingParen(text, 0);
    if (close !== text.length - 1) break;
    text = text.slice(1, -1).trim();
  }
  return text;
}

function splitTop(expr, ops) {
  let depth = 0;
  for (let index = 0; index < expr.length; index += 1) {
    const char = expr[index];
    if (char === "(") depth += 1;
    else if (char === ")") depth -= 1;
    else if (depth === 0 && ops.includes(char) && index > 0) {
      return { left: expr.slice(0, index).trim(), op: char, right: expr.slice(index + 1).trim() };
    }
  }
  return null;
}

function evalCond(expr, env) {
  const text = stripOuterParens(expr);
  if (text === "dark" || text === "largeText") return env[text];
  if (/colorScheme\s*==\s*\.dark|testDarkAppearance/.test(text)) return env.dark;
  if (/colorScheme\s*==\s*\.light/.test(text)) return !env.dark;
  if (/dynamicTypeSize\s*>\s*\.large/.test(text)) return env.largeText;
  if (text.startsWith("!")) return !evalCond(text.slice(1), env);
  assert.fail(`condition: ${text}`);
}

function evalExpr(expr, env, fns) {
  const text = stripOuterParens(expr);
  const ternary = splitTop(text, "?");
  if (ternary) {
    const colon = splitTop(ternary.right, ":");
    assert.notEqual(colon, null, text);
    return evalCond(ternary.left, env)
      ? evalExpr(colon.left, env, fns)
      : evalExpr(colon.right, env, fns);
  }
  const add = splitTop(text, "+-");
  if (add) {
    const left = evalExpr(add.left, env, fns);
    const right = evalExpr(add.right, env, fns);
    return add.op === "+" ? left + right : left - right;
  }
  const mul = splitTop(text, "*/");
  if (mul) {
    const left = evalExpr(mul.left, env, fns);
    const right = evalExpr(mul.right, env, fns);
    return mul.op === "*" ? left * right : left / right;
  }
  const cgfloat = /^CGFloat\((.+)\)$/s.exec(text);
  if (cgfloat) return evalExpr(cgfloat[1], env, fns);
  const call = /^(?:ToolbarCapsuleGap\.)?([A-Za-z_]\w*)\((.*)\)$/s.exec(text);
  if (call && Object.hasOwn(fns, call[1])) {
    const args = call[2];
    const next = { ...env };
    if (/dark:\s*(.+)/s.test(args)) {
      const darkArg = /dark:\s*([^,]+)/.exec(args);
      if (darkArg) next.dark = evalCond(darkArg[1], env);
    }
    if (/largeText:\s*(.+)/s.test(args)) {
      const largeArg = /largeText:\s*([^)]+)/s.exec(args);
      if (largeArg) next.largeText = evalCond(largeArg[1].trim().replace(/,$/, ""), env);
    }
    return fns[call[1]](next);
  }
  if (text === "points" || text.endsWith(".points")) return env.points;
  if (text === "nativeToolbarSpacing" || text.endsWith(".nativeToolbarSpacing")) {
    return env.nativeToolbarSpacing;
  }
  if (text === "captureScale" || text.endsWith(".captureScale")) return env.captureScale;
  const number = Number(text);
  assert.equal(Number.isFinite(number), true, text);
  return number;
}

function paddingCalls(block, side) {
  const found = [];
  const re = new RegExp(String.raw`padding\(\.(${side}|horizontal),\s*`, "g");
  for (const match of block.matchAll(re)) {
    const open = block.indexOf("(", match.index);
    const close = matchingParen(block, open);
    assert.notEqual(close, -1, match[0]);
    const inside = block.slice(open + 1, close);
    const comma = inside.indexOf(",");
    found.push(inside.slice(comma + 1).trim());
  }
  return found;
}

function frameWidthCalls(block) {
  const found = [];
  const re = /\.frame\(width:\s*/g;
  for (const match of block.matchAll(re)) {
    const open = block.indexOf("(", match.index);
    const close = matchingParen(block, open);
    assert.notEqual(close, -1, match[0]);
    const inside = block.slice(open + 1, close);
    let depth = 0;
    let end = inside.length;
    for (let index = 0; index < inside.length; index += 1) {
      const char = inside[index];
      if (char === "(") depth += 1;
      else if (char === ")") depth -= 1;
      else if (char === "," && depth === 0) {
        end = index;
        break;
      }
    }
    const labeled = inside.slice(0, end).replace(/^width:\s*/, "").trim();
    found.push(labeled);
  }
  return found;
}

function hstackSpacing(block, env, fns) {
  const match = /HStack\([^)]*spacing:\s*([^,\)]+)/.exec(block);
  if (!match) return 0;
  return evalExpr(match[1], env, fns);
}

function loadBarSources() {
  const gap = read(GAP_SOURCE);
  const app = read("HermedBots/App/HermedBotsApp.swift");
  const conversation = read("HermedBots/Conversation/ConversationView.swift");
  const stop = read("HermedBots/KillSwitch/StopAllButton.swift");
  return {
    gap,
    points: staticDouble(gap, "points"),
    nativeToolbarSpacing: staticDouble(gap, "nativeToolbarSpacing"),
    captureScale: staticDouble(gap, "captureScale"),
    resolvedBody: functionBody(gap, "resolved"),
    extraBody: functionBody(gap, "extraContainerSpacing"),
    freePixelsBody: functionBody(gap, "freePixels"),
    windowBar: firstBlock(app, ".toolbar {"),
    sessionBar: firstBlock(conversation, ".toolbar {"),
    stopButton: firstBlock(stop, "private var button"),
  };
}

function functionsFor(sources) {
  const fns = {};
  fns.resolved = (env) => evalExpr(sources.resolvedBody, env, fns);
  fns.extraContainerSpacing = (env) => evalExpr(sources.extraBody, env, fns);
  fns.freePixels = (env) => evalExpr(sources.freePixelsBody, env, fns);
  return fns;
}

function producedCapsuleGap(sources, appearance, size) {
  const env = {
    dark: appearance === "dark",
    largeText: size === "large",
    points: sources.points,
    nativeToolbarSpacing: sources.nativeToolbarSpacing,
    captureScale: sources.captureScale,
  };
  const fns = functionsFor(sources);
  const grouped = (() => {
    for (const block of [sources.windowBar, sources.sessionBar, sources.stopButton]) {
      if (!block.includes("Tout arrêter") || !block.includes("Nouvelle session")) continue;
      const match = /HStack\([^)]*spacing:\s*([^,\)]+)/.exec(block);
      if (match) return evalExpr(match[1], env, fns);
    }
    return null;
  })();
  if (grouped != null) return grouped;
  let extra = hstackSpacing(sources.sessionBar, env, fns);
  for (const expr of frameWidthCalls(sources.sessionBar)) {
    extra += evalExpr(expr, env, fns);
  }
  return sources.nativeToolbarSpacing + extra;
}

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

function decodePng8(buf) {
  if (buf[0] !== 0x89 || buf[1] !== 0x50 || buf[2] !== 0x4e || buf[3] !== 0x47) {
    throw new Error("not png");
  }
  let i = 8;
  let w;
  let h;
  let bit;
  let ct;
  const idat = [];
  while (i + 12 <= buf.length) {
    const ln = buf.readUInt32BE(i);
    const tag = buf.toString("ascii", i + 4, i + 8);
    const chunk = buf.subarray(i + 8, i + 8 + ln);
    if (tag === "IHDR") {
      w = chunk.readUInt32BE(0);
      h = chunk.readUInt32BE(4);
      bit = chunk[8];
      ct = chunk[9];
    } else if (tag === "IDAT") {
      idat.push(chunk);
    } else if (tag === "IEND") {
      break;
    }
    i += 12 + ln;
  }
  if (bit !== 8 || (ct !== 2 && ct !== 6)) throw new Error("png");
  const channels = ct === 6 ? 4 : 3;
  const bpp = channels;
  const stride = w * bpp;
  const raw = inflateSync(Buffer.concat(idat));
  const rgb = Buffer.alloc(w * h * 3);
  let prev = Buffer.alloc(stride);
  let pos = 0;
  for (let y = 0; y < h; y += 1) {
    const filter = raw[pos];
    pos += 1;
    const scan = Buffer.from(raw.subarray(pos, pos + stride));
    pos += stride;
    if (filter === 1) {
      for (let x = bpp; x < stride; x += 1) scan[x] = (scan[x] + scan[x - bpp]) & 255;
    } else if (filter === 2) {
      for (let x = 0; x < stride; x += 1) scan[x] = (scan[x] + prev[x]) & 255;
    } else if (filter === 3) {
      for (let x = 0; x < stride; x += 1) {
        const a = x >= bpp ? scan[x - bpp] : 0;
        scan[x] = (scan[x] + Math.floor((a + prev[x]) / 2)) & 255;
      }
    } else if (filter === 4) {
      for (let x = 0; x < stride; x += 1) {
        const a = x >= bpp ? scan[x - bpp] : 0;
        const c = x >= bpp ? prev[x - bpp] : 0;
        scan[x] = (scan[x] + paeth(a, prev[x], c)) & 255;
      }
    } else if (filter !== 0) {
      throw new Error("filter");
    }
    for (let x = 0; x < w; x += 1) {
      const o = (y * w + x) * 3;
      const s = x * bpp;
      rgb[o] = scan[s];
      rgb[o + 1] = scan[s + 1];
      rgb[o + 2] = scan[s + 2];
    }
    prev = scan;
  }
  return { w, h, rgb };
}

function dist2(c, bg) {
  const dr = c[0] - bg[0];
  const dg = c[1] - bg[1];
  const db = c[2] - bg[2];
  return dr * dr + dg * dg + db * db;
}

function freePixelsAtY(rgb, w, h, y, bg) {
  assert.ok(y >= 0 && y < h, `y=${y}`);
  const chrome = [];
  let start = null;
  const isFree = (x) => {
    const o = (y * w + x) * 3;
    return dist2([rgb[o], rgb[o + 1], rgb[o + 2]], bg) <= 30 * 30;
  };
  for (let x = 0; x <= w; x += 1) {
    const ink = x < w && !isFree(x);
    if (ink && start == null) start = x;
    if (!ink && start != null) {
      chrome.push([start, x - 1]);
      start = null;
    }
  }
  assert.ok(chrome.length >= 2, "deux capsules");
  const left = chrome[chrome.length - 2];
  const right = chrome[chrome.length - 1];
  return right[0] - left[1] - 1;
}

function paintGapShot({ leftEnd, free, bg, fill }) {
  const y = SCAN_Y;
  const rightStart = leftEnd + free + 1;
  const w = rightStart + 80;
  const h = 80;
  const rgb = rgbCanvas(w, h, bg);
  blitRgb(rgb, w, 40, y - 10, leftEnd - 39, 20, fill);
  blitRgb(rgb, w, rightStart, y - 10, 60, 20, fill);
  return { w, h, rgb, png: encodePngRgb(w, h, rgb), bg };
}

const SHOTS = [
  { name: "piste1-empty-conversation-standard-light.png", leftEnd: 1714, bg: [180, 180, 185], fill: [250, 250, 255] },
  { name: "piste1-empty-conversation-standard-dark.png", leftEnd: 1714, bg: [40, 38, 45], fill: [100, 96, 110] },
  { name: "piste1-empty-conversation-large-light.png", leftEnd: 1866, bg: [180, 180, 185], fill: [250, 250, 255] },
  { name: "piste1-empty-conversation-large-dark.png", leftEnd: 1866, bg: [40, 38, 45], fill: [100, 96, 110] },
];

test("l'écart rendu entre Tout arrêter et Nouvelle session est 13 pt dans les quatre configurations", () => {
  const sources = loadBarSources();
  assert.equal(sources.points, 13);
  assert.equal(sources.captureScale, 2);
  assert.match(sources.sessionBar, /ToolbarCapsuleGap\.extraContainerSpacing/);
  assert.match(sources.sessionBar, /Color\.clear/);
  assert.match(sources.sessionBar, /sharedBackgroundVisibility\(\.hidden\)/);
  assert.match(sources.sessionBar, /HStack\(spacing: 0\)/);
  assert.equal(paddingCalls(sources.sessionBar, "leading").length, 0);
  assert.doesNotMatch(sources.sessionBar, /extraLeadingPadding/);
  assert.doesNotMatch(sources.gap, /extraLeadingPadding/);
  assert.match(sources.stopButton, /Tout arrêter/);
  assert.match(sources.sessionBar, /Nouvelle session/);
  assert.match(sources.windowBar, /StopAllButton/);

  for (const appearance of APPEARANCES) {
    for (const size of SIZES) {
      const gap = producedCapsuleGap(sources, appearance, size);
      assert.equal(gap, sources.points, `${appearance} ${size}`);
      const env = {
        dark: appearance === "dark",
        largeText: size === "large",
        points: sources.points,
        nativeToolbarSpacing: sources.nativeToolbarSpacing,
        captureScale: sources.captureScale,
      };
      const pixels = functionsFor(sources).freePixels(env);
      assert.equal(pixels, TARGET_FREE_PX, `${appearance} ${size} px`);
    }
  }
});

test("un padding interne de capsule n'élargit pas l'écart rendu", () => {
  const sources = loadBarSources();
  const padded = {
    ...sources,
    sessionBar: `${sources.sessionBar}\n.padding(.leading, colorScheme == .dark ? CGFloat(5) : 6)\n`,
    stopButton: `${sources.stopButton}\n.padding(.trailing, colorScheme == .dark ? CGFloat(5) : 0)\n`,
  };
  for (const appearance of APPEARANCES) {
    for (const size of SIZES) {
      assert.equal(producedCapsuleGap(padded, appearance, size), sources.points, `${appearance} ${size}`);
    }
  }
});

test("l'ancien padding d'appoint laisse l'écart à 7 pt, pas 13", () => {
  const sources = loadBarSources();
  const oldStyle = {
    ...sources,
    sessionBar: [
      ".toolbar {",
      "  ToolbarItem(placement: .primaryAction) {",
      '    Button { model.newSession() } label: { Label("Nouvelle session", systemImage: "square.and.pencil") }',
      "    .padding(.leading, ToolbarCapsuleGap.extraContainerSpacing(",
      "      dark: colorScheme == .dark,",
      "      largeText: dynamicTypeSize > .large",
      "    ))",
      "  }",
      "}",
    ].join("\n"),
  };
  for (const appearance of APPEARANCES) {
    for (const size of SIZES) {
      const gap = producedCapsuleGap(oldStyle, appearance, size);
      assert.equal(gap, sources.nativeToolbarSpacing, `${appearance} ${size}`);
      assert.notEqual(gap, sources.points, `${appearance} ${size}`);
    }
  }
});

test("un spacer de conteneur trop étroit échoue la cible de 13 pt", () => {
  const sources = loadBarSources();
  const mutated = {
    ...sources,
    extraBody: "dark ? 5 : 0",
  };
  assert.equal(producedCapsuleGap(mutated, "light", "standard"), sources.nativeToolbarSpacing);
  assert.equal(producedCapsuleGap(mutated, "dark", "standard"), sources.nativeToolbarSpacing + 5);
  assert.notEqual(producedCapsuleGap(mutated, "dark", "standard"), sources.points);
});

test("26 px libres à y=52 sur les quatre captures synthétiques, 14 px refusés", () => {
  for (const shot of SHOTS) {
    const wide = paintGapShot({ ...shot, free: TARGET_FREE_PX });
    const decoded = decodePng8(wide.png);
    assert.equal(decoded.w, wide.w);
    assert.equal(decoded.h, wide.h);
    const fromRgb = freePixelsAtY(wide.rgb, wide.w, wide.h, SCAN_Y, shot.bg);
    const fromPng = freePixelsAtY(decoded.rgb, decoded.w, decoded.h, SCAN_Y, shot.bg);
    assert.equal(fromRgb, TARGET_FREE_PX, shot.name);
    assert.equal(fromPng, TARGET_FREE_PX, `${shot.name} png`);

    const narrow = paintGapShot({ ...shot, free: OLD_FREE_PX });
    const oldPx = freePixelsAtY(narrow.rgb, narrow.w, narrow.h, SCAN_Y, shot.bg);
    assert.equal(oldPx, OLD_FREE_PX, `${shot.name} ancien`);
    assert.notEqual(oldPx, TARGET_FREE_PX, `${shot.name} ancien ≠ 26`);
  }
});
