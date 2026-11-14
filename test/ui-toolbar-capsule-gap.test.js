"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const APPEARANCES = ["light", "dark"];
const SIZES = ["standard", "large"];
const GAP_SOURCE = "Packages/HermesAdapter/Sources/AppSettings/ToolbarCapsuleGap.swift";

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

function loadBarSources() {
  const gap = read(GAP_SOURCE);
  const app = read("HermedBots/App/HermedBotsApp.swift");
  const conversation = read("HermedBots/Conversation/ConversationView.swift");
  const stop = read("HermedBots/KillSwitch/StopAllButton.swift");
  return {
    gap,
    points: staticDouble(gap, "points"),
    nativeToolbarSpacing: staticDouble(gap, "nativeToolbarSpacing"),
    resolvedBody: functionBody(gap, "resolved"),
    extraBody: functionBody(gap, "extraLeadingPadding"),
    windowBar: firstBlock(app, ".toolbar {"),
    sessionBar: firstBlock(conversation, ".toolbar {"),
    stopButton: firstBlock(stop, "private var button"),
  };
}

function functionsFor(sources) {
  const fns = {};
  fns.resolved = (env) => evalExpr(sources.resolvedBody, env, fns);
  fns.extraLeadingPadding = (env) => evalExpr(sources.extraBody, env, fns);
  return fns;
}

function producedCapsuleGap(sources, appearance, size) {
  const env = {
    dark: appearance === "dark",
    largeText: size === "large",
    points: sources.points,
    nativeToolbarSpacing: sources.nativeToolbarSpacing,
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
  const base = grouped == null ? sources.nativeToolbarSpacing : grouped;
  let extras = 0;
  for (const expr of paddingCalls(sources.stopButton, "trailing")) {
    extras += evalExpr(expr, env, fns);
  }
  for (const expr of paddingCalls(sources.sessionBar, "leading")) {
    extras += evalExpr(expr, env, fns);
  }
  return base + extras;
}

test("l'écart rendu entre Tout arrêter et Nouvelle session est 13 pt dans les quatre configurations", () => {
  const sources = loadBarSources();
  assert.equal(sources.points, 13);
  assert.match(sources.sessionBar, /ToolbarCapsuleGap\.extraLeadingPadding/);
  assert.match(sources.stopButton, /Tout arrêter/);
  assert.match(sources.sessionBar, /Nouvelle session/);
  assert.match(sources.windowBar, /StopAllButton/);

  for (const appearance of APPEARANCES) {
    for (const size of SIZES) {
      const gap = producedCapsuleGap(sources, appearance, size);
      assert.equal(gap, sources.points, `${appearance} ${size}`);
    }
  }
});

test("un padding sombre de 5 pt via CGFloat change l'écart rendu", () => {
  const sources = loadBarSources();
  const patched = {
    ...sources,
    stopButton: `${sources.stopButton}\n.padding(.trailing, colorScheme == .dark ? CGFloat(5) : 0)\n`,
  };
  const light = producedCapsuleGap(patched, "light", "standard");
  const darkStandard = producedCapsuleGap(patched, "dark", "standard");
  const darkLarge = producedCapsuleGap(patched, "dark", "large");
  assert.equal(light, sources.points);
  assert.equal(darkStandard, sources.points + 5);
  assert.equal(darkLarge, sources.points + 5);
  assert.notEqual(light, darkStandard);
});
