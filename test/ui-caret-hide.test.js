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

test("HVShot masque le caret avant la seule capture XCUITest, et le compositeur le rend transparent en mode test", () => {
  const shot = read("HermedBotsUITests/HVShot.swift");
  const capture = firstBlock(shot, "static func capture(_ name: String, _ window: XCUIElement)");
  const hideAt = capture.indexOf("hideCaret(");
  const shotAt = capture.indexOf("window.screenshot()");
  assert.notEqual(hideAt, -1, "HVShot.capture n'appelle pas hideCaret");
  assert.notEqual(shotAt, -1, "HVShot.capture n'appelle pas screenshot()");
  assert.ok(hideAt < shotAt, "hideCaret doit précéder screenshot()");
  assert.match(shot, /static func hideCaret\(in /);
  assert.match(shot, /hasKeyboardFocus/);
  assert.match(shot, /composerInput/);
  assert.doesNotMatch(shot, /\.escape/);

  const composer = read("HermedBots/Conversation/ComposerView.swift");
  const tint = firstBlock(composer, "private struct ComposerCaretTint");
  assert.match(composer, /@Environment\(\\\.hideComposerCaret\)/);
  assert.match(composer, /\.modifier\(ComposerCaretTint\(hidden: hideComposerCaret\)\)/);
  assert.match(tint, /tint\(\.clear\)/);
  assert.match(tint, /if hidden/);

  const app = read("HermedBots/App/HermedBotsApp.swift");
  assert.match(app, /\.environment\(\\\.hideComposerCaret, model\.isTestMode\)/);

  const design = read("HermedBots/Shared/Design.swift");
  assert.match(design, /@Entry var hideComposerCaret = false/);

  const uiTests = join(ROOT, "HermedBotsUITests");
  for (const name of readdirSync(uiTests)) {
    if (!name.endsWith(".swift")) continue;
    const source = read(join("HermedBotsUITests", name));
    const hits = source.match(/\.screenshot\(\)/g) || [];
    if (name === "HVShot.swift") {
      assert.equal(hits.length, 1, "HVShot.swift doit garder un seul screenshot()");
      continue;
    }
    assert.equal(hits.length, 0, `${name} capture hors HVShot`);
  }
});
