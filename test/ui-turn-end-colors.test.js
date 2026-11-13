"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const WARM = /\.(orange|yellow|amber)\b/;
const RGB = /Color\(rgb:|#[0-9A-Fa-f]{3,8}\b/;

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

function switchMap(block) {
  const map = {};
  const re = /case\s+([^:\n]+):\s*(\.[A-Za-z][A-Za-z0-9]*)/g;
  let match;
  while ((match = re.exec(block))) {
    const value = match[2];
    for (const raw of match[1].split(",")) {
      const name = raw.trim().replace(/^\./, "");
      assert.equal(map[name], undefined, name);
      map[name] = value;
    }
  }
  return map;
}

test("la pastille annulée est un gris secondaire, les autres états gardent leur teinte", () => {
  const view = read("HermedBots/Conversation/ConversationView.swift");
  const row = firstBlock(view, "private struct TurnEndRow");
  assert.equal((row.match(/private var color: Color/g) || []).length, 1);

  const colors = switchMap(firstBlock(row, "private var color: Color"));
  assert.deepEqual(colors, {
    completed: ".green",
    failed: ".red",
    cancelled: ".secondary",
    interrupted: ".orange",
  });
  assert.doesNotMatch(colors.cancelled, WARM);
  assert.doesNotMatch(colors.cancelled, RGB);
  assert.match(colors.cancelled, /^\.(secondary|tertiary)$/);

  assert.equal(colors.interrupted, ".orange");
  assert.equal(colors.completed, ".green");
  assert.equal(colors.failed, ".red");
  assert.doesNotMatch(row, /case \.cancelled,\s*\.interrupted/);
  assert.doesNotMatch(row, RGB);

  assert.match(row, /Image\(systemName: symbol\)\.foregroundStyle\(color\)/);
  assert.match(row, /\.background\(color\.opacity\(0\.12\), in: \.rect\(cornerRadius: 12\)\)/);

  assert.match(row, /case \.cancelled: String\(localized: "Tour annulé"\)/);
  assert.match(row, /case \.interrupted: String\(localized: "Tour interrompu"\)/);
  assert.match(row, /case \.completed: String\(localized: "Tour terminé"\)/);
  assert.match(row, /case \.failed: String\(localized: "Tour échoué"\)/);
  assert.match(row, /case \.cancelled: "stop\.circle\.fill"/);
  assert.match(row, /case \.interrupted: "bolt\.slash\.fill"/);
  assert.match(row, /case \.completed: "checkmark\.circle\.fill"/);
  assert.match(row, /case \.failed: "xmark\.octagon\.fill"/);
});
