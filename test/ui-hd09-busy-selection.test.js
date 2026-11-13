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

test("la capture hd09-busy presse ⏎ pendant le tour, sans clic d'unfocus", () => {
  const source = read("HermedBotsUITests/SixActions.swift");
  const body = firstBlock(source, "func testSendingWhileATurnRunsIsRefusedWithoutSendingAnythingExtra()");
  assert.match(body, /type\("suite en attente"/);
  assert.match(body, /typeKey\(\.return/);
  assert.match(body, /HVShot\.capture\("hd09-busy"/);
  const typeAt = body.indexOf('type("suite en attente"');
  const returnAt = body.indexOf("typeKey(.return");
  const captureAt = body.indexOf('HVShot.capture("hd09-busy"');
  assert.ok(typeAt !== -1 && typeAt < returnAt, "le brouillon précède ⏎");
  assert.ok(returnAt !== -1 && returnAt < captureAt, "⏎ précède la capture");
  assert.equal(body.includes("coordinate("), false, "pas de clic hors champ avant la capture");
  assert.doesNotMatch(body, /hideCaret/);
  assert.doesNotMatch(body, /hasKeyboardFocus/);
  assert.doesNotMatch(body, /typeKey\(\.escape/);
});

test("HVShot ne retire pas le focus du compositeur avant screenshot()", () => {
  const shot = firstBlock(read("HermedBotsUITests/HVShot.swift"), "enum HVShot");
  assert.match(shot, /window\.screenshot\(\)/);
  assert.doesNotMatch(shot, /hideCaret/);
  assert.doesNotMatch(shot, /hasKeyboardFocus/);
  assert.doesNotMatch(shot, /\.click\(\)/);
  assert.doesNotMatch(shot, /statusVersion/);
  assert.doesNotMatch(shot, /typeKey\(\.escape/);
  const capture = firstBlock(shot, "static func capture(_ name: String, _ window: XCUIElement)");
  const shotCall = capture.indexOf("window.screenshot()");
  assert.notEqual(shotCall, -1);
  assert.equal(capture.slice(0, shotCall).includes("click"), false);
});

test("⏎ refuse d'envoyer sans laisser une sélection : focus rendu, caret à la fin", () => {
  const composer = read("HermedBots/Conversation/ComposerView.swift");
  assert.match(composer, /\.onSubmit\(submit\)/);
  assert.match(composer, /ComposerSubmitRepair\(generation: submitGeneration\)/);
  assert.match(composer, /\.modifier\(ComposerCaretTint\(hidden: hideComposerCaret\)\)/);
  assert.match(composer, /tint\(\.clear\)/);

  const submit = firstBlock(composer, "private func submit");
  assert.match(submit, /model\.send\(\)/);
  assert.match(submit, /focused = true/);
  assert.match(submit, /submitGeneration \+= 1/);

  const range = firstBlock(read("HermedBots/Conversation/ComposerSubmit.swift"), "enum ComposerSubmit");
  assert.match(range, /static func collapsedRange\(of text: String\) -> NSRange/);
  assert.match(range, /NSRange\(location: \(text as NSString\)\.length, length: 0\)/);

  const repair = firstBlock(composer, "private struct ComposerSubmitRepair");
  assert.match(repair, /generation != context\.coordinator\.applied/);
  assert.match(repair, /makeFirstResponder/);
  assert.match(repair, /ComposerSubmit\.collapsedRange/);
  assert.match(repair, /isEditable/);
  assert.doesNotMatch(repair, /hasKeyboardFocus/);

  const project = read("HermedBots.xcodeproj/project.pbxproj");
  assert.match(project, /ComposerSubmit\.swift in Sources/);
});

test("le masquage du caret en mode test n'est pas un clic d'unfocus", () => {
  const uiTests = join(ROOT, "HermedBotsUITests");
  for (const name of readdirSync(uiTests)) {
    if (!name.endsWith(".swift")) continue;
    const source = read(join("HermedBotsUITests", name));
    assert.doesNotMatch(source, /hasKeyboardFocus/, `${name} : hasKeyboardFocus`);
    assert.doesNotMatch(source, /func hideCaret/, `${name} : hideCaret`);
  }
});
