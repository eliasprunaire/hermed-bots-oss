"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
// 26 px mesurés en clair sur capture @2x, soit 13 pt : valeur retenue
const LIGHT_POINTS = 13;
const APPEARANCES = ["light", "dark"];
const SIZES = ["standard", "large"];

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

function layoutLines(block) {
  return block
    .split("\n")
    .filter((line) => /padding|spacing:|offset\(|shadow\(|\.frame\(/.test(line))
    .join("\n");
}

function sumSidePadding(block, side) {
  const re = new RegExp(String.raw`padding\(\.${side},\s*(\d+(?:\.\d+)?)\)`, "g");
  let sum = 0;
  for (const match of block.matchAll(re)) sum += Number(match[1]);
  const horizontal = block.matchAll(/padding\(\.horizontal,\s*(\d+(?:\.\d+)?)\)/g);
  for (const match of horizontal) sum += Number(match[1]);
  return sum;
}

function ternaryExtras(block, appearance, wide) {
  const layout = layoutLines(block);
  let extra = 0;
  const darkFirst = /(?:colorScheme\s*==\s*\.dark|testDarkAppearance)\s*\?\s*([-\d.]+)\s*:\s*([-\d.]+)/g;
  for (const match of layout.matchAll(darkFirst)) {
    extra += appearance === "dark" ? Number(match[1]) : Number(match[2]);
  }
  const lightFirst = /colorScheme\s*==\s*\.light\s*\?\s*([-\d.]+)\s*:\s*([-\d.]+)/g;
  for (const match of layout.matchAll(lightFirst)) {
    extra += appearance === "light" ? Number(match[1]) : Number(match[2]);
  }
  const sizeFirst = /(?:\bwide\b|\bisLarge\b|\blarge\b)\s*\?\s*([-\d.]+)\s*:\s*([-\d.]+)/g;
  for (const match of layout.matchAll(sizeFirst)) {
    extra += wide ? Number(match[1]) : Number(match[2]);
  }
  return extra;
}

function groupedSpacing(blocks) {
  for (const block of blocks) {
    if (!block.includes("Tout arrêter") || !block.includes("Nouvelle session")) continue;
    const match = /HStack\([^)]*spacing:\s*([-\d.]+)/.exec(block);
    if (match) return Number(match[1]);
  }
  return null;
}

function loadBarSources() {
  const app = read("HermedBots/App/HermedBotsApp.swift");
  const conversation = read("HermedBots/Conversation/ConversationView.swift");
  const stop = read("HermedBots/KillSwitch/StopAllButton.swift");
  return {
    windowBar: firstBlock(app, ".toolbar {"),
    sessionBar: firstBlock(conversation, ".toolbar {"),
    stopButton: firstBlock(stop, "private var button"),
  };
}

function producedCapsuleGap(sources, appearance, size) {
  const blocks = [sources.windowBar, sources.sessionBar, sources.stopButton];
  const grouped = groupedSpacing(blocks);
  const base = grouped == null ? LIGHT_POINTS : grouped;
  const facing = sumSidePadding(sources.stopButton, "trailing")
    + sumSidePadding(sources.sessionBar, "leading");
  const wide = size === "large";
  let extras = facing;
  for (const block of blocks) extras += ternaryExtras(block, appearance, wide);
  return base + extras;
}

test("l'écart produit entre Tout arrêter et Nouvelle session est le même en clair et en sombre", () => {
  const sources = loadBarSources();
  assert.match(sources.stopButton, /Tout arrêter/);
  assert.match(sources.sessionBar, /Nouvelle session/);
  assert.match(sources.windowBar, /StopAllButton/);

  const lightStandard = producedCapsuleGap(sources, "light", "standard");
  assert.equal(lightStandard, LIGHT_POINTS);

  for (const appearance of APPEARANCES) {
    for (const size of SIZES) {
      assert.equal(
        producedCapsuleGap(sources, appearance, size),
        lightStandard,
        `${appearance} ${size}`,
      );
    }
  }
});

test("un padding qui dépend du thème change l'écart produit", () => {
  const sources = loadBarSources();
  const patched = {
    ...sources,
    stopButton: `${sources.stopButton}\n.padding(.trailing, colorScheme == .dark ? 5 : 0)\n`,
  };
  assert.equal(producedCapsuleGap(patched, "light", "standard"), LIGHT_POINTS);
  assert.equal(producedCapsuleGap(patched, "dark", "standard"), LIGHT_POINTS + 5);
  assert.equal(producedCapsuleGap(patched, "dark", "large"), LIGHT_POINTS + 5);
  assert.notEqual(
    producedCapsuleGap(patched, "light", "standard"),
    producedCapsuleGap(patched, "dark", "standard"),
  );
});
