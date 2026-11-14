"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
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
    if (source[index] === "{") depth += 1;
    else if (source[index] === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  assert.fail(marker);
}

test("au moment de la capture, le pointeur n'est sur aucun contrôle à info-bulle", () => {
  const shot = firstBlock(read("HermedBotsUITests/HVShot.swift"), "enum HVShot");
  const capture = firstBlock(shot, "static func capture(_ name: String, _ window: XCUIElement)");
  const shotCall = capture.indexOf("window.screenshot()");
  assert.notEqual(shotCall, -1);
  const before = capture.slice(0, shotCall);
  assert.match(before, /collapseBeforeCapture\(\)/);
  assert.match(before, /parkPointer\(in: window\)/);
  assert.doesNotMatch(before, /\.click\(/);
  assert.doesNotMatch(before, /typeKey/);
  assert.doesNotMatch(before, /resignFirstResponder/);
  assert.doesNotMatch(before, /makeFirstResponder/);

  const park = firstBlock(shot, "static func parkPointer");
  assert.match(park, /neutralPointerOffset/);
  assert.match(park, /\.hover\(\)/);
  assert.doesNotMatch(park, /\.click\(/);
  assert.doesNotMatch(park, /typeKey/);

  assert.match(shot, /neutralPointerOffset/);
  assert.match(shot, /dx: 0\.5/);
  assert.match(shot, /dy: 0\.02/);

  const selection = read("HermedBots/Conversation/CaptureSelection.swift");
  const install = firstBlock(selection, "static func install");
  assert.match(install, /collapseOpenEditors\(\)/);
  assert.match(install, /dismissOpenToolTips\(\)/);

  const dismiss = firstBlock(selection, "static func dismissOpenToolTips");
  assert.match(dismiss, /isTooltipWindow/);
  assert.match(dismiss, /orderOut/);
  assert.doesNotMatch(dismiss, /resignFirstResponder/);
  assert.doesNotMatch(dismiss, /makeFirstResponder/);
  assert.doesNotMatch(dismiss, /\.click\(/);

  const help = firstBlock(selection, "static func helpTag(at");
  assert.match(help, /toolTip/);
  assert.match(help, /hitTest/);

  const unit = read("HermedBotsTests/CaptureSelectionTests.swift");
  assert.match(unit, /Réglages/);
  assert.match(unit, /hv-bot-b/);
  assert.match(unit, /helpTag\(at:/);
  assert.match(unit, /neutralPoint/);
  assert.match(unit, /dismissOpenToolTips/);
  assert.match(unit, /firstResponder === editor/);
});

test("le focus du compositeur et la désélection restent : pas de clic, pas de resign", () => {
  const shot = firstBlock(read("HermedBotsUITests/HVShot.swift"), "enum HVShot");
  assert.doesNotMatch(shot, /\.click\(/);
  assert.doesNotMatch(shot, /resignFirstResponder/);
  assert.doesNotMatch(shot, /makeFirstResponder/);
  assert.doesNotMatch(shot, /hasKeyboardFocus/);

  const composer = read("HermedBots/Conversation/ComposerView.swift");
  const repair = firstBlock(composer, "private struct ComposerSubmitRepair");
  assert.match(repair, /makeFirstResponder/);
  assert.match(repair, /ComposerSubmit\.collapsedRange/);

  const selection = read("HermedBots/Conversation/CaptureSelection.swift");
  assert.doesNotMatch(selection, /resignFirstResponder/);
  assert.doesNotMatch(selection, /makeFirstResponder/);
});
