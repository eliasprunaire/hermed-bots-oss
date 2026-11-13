"use strict";

const assert = require("node:assert/strict");
const { readdirSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");

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

test("le compositeur rend le caret transparent en mode test, sans API XCTest inexistante", () => {
  const composer = read("HermedBots/Conversation/ComposerView.swift");
  const tint = firstBlock(composer, "private struct ComposerCaretTint");
  assert.match(composer, /@Environment\(\\\.hideComposerCaret\)/);
  assert.match(composer, /\.modifier\(ComposerCaretTint\(hidden: hideComposerCaret\)\)/);
  assert.match(tint, /if hidden/);
  assert.match(tint, /tint\(\.clear\)/);

  const app = read("HermedBots/App/HermedBotsApp.swift");
  assert.match(app, /\.environment\(\\\.hideComposerCaret, model\.isTestMode\)/);

  const design = read("HermedBots/Shared/Design.swift");
  assert.match(design, /@Entry var hideComposerCaret = false/);

  const uiTests = join(ROOT, "HermedBotsUITests");
  for (const name of readdirSync(uiTests)) {
    if (!name.endsWith(".swift")) continue;
    const source = read(join("HermedBotsUITests", name));
    assert.doesNotMatch(source, /hasKeyboardFocus/, `${name} : hasKeyboardFocus`);
  }
});
