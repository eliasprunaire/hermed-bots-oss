"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const REQUEST = "com.hermedbots.hv.collapse-selection";
const DONE = "com.hermedbots.hv.collapse-selection.done";

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

test("au moment de la capture, la plage sélectionnée du champ a une longueur nulle", () => {
  const shot = firstBlock(read("HermedBotsUITests/HVShot.swift"), "enum HVShot");
  const capture = firstBlock(shot, "static func capture(_ name: String, _ window: XCUIElement)");
  const shotCall = capture.indexOf("window.screenshot()");
  assert.notEqual(shotCall, -1);
  const before = capture.slice(0, shotCall);
  assert.match(before, /collapseBeforeCapture\(\)/);
  assert.doesNotMatch(before, /\.click\(/);
  assert.doesNotMatch(before, /typeKey/);
  assert.doesNotMatch(before, /resignFirstResponder/);
  assert.doesNotMatch(shot, /hideCaret/);
  assert.doesNotMatch(shot, /hasKeyboardFocus/);
  assert.doesNotMatch(shot, /makeFirstResponder/);

  const collapse = firstBlock(shot, "static func collapseBeforeCapture");
  assert.match(collapse, new RegExp(REQUEST.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(collapse, new RegExp(DONE.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.doesNotMatch(collapse, /\.click\(/);
  assert.doesNotMatch(collapse, /typeKey/);
  assert.doesNotMatch(collapse, /resignFirstResponder/);
  assert.doesNotMatch(collapse, /makeFirstResponder/);

  const selection = read("HermedBots/Conversation/CaptureSelection.swift");
  const apply = firstBlock(selection, "static func apply(to editor: NSText)");
  assert.match(apply, /setSelectedRange\(ComposerSubmit\.collapsedRange\(of: editor\.string\)\)/);
  assert.doesNotMatch(apply, /makeFirstResponder/);
  assert.doesNotMatch(apply, /resignFirstResponder/);

  const collapseEditors = firstBlock(selection, "static func collapseOpenEditors");
  assert.match(collapseEditors, /apply\(to:/);
  assert.doesNotMatch(collapseEditors, /makeFirstResponder/);
  assert.doesNotMatch(collapseEditors, /resignFirstResponder/);

  const walk = firstBlock(selection, "private static func collapse(in view: NSView)");
  assert.match(walk, /isEditable/);
  assert.match(walk, /apply\(to:/);
  assert.doesNotMatch(walk, /makeFirstResponder/);
  assert.doesNotMatch(walk, /resignFirstResponder/);

  const range = firstBlock(read("HermedBots/Conversation/ComposerSubmit.swift"), "enum ComposerSubmit");
  assert.match(range, /NSRange\(location: \(text as NSString\)\.length, length: 0\)/);

  const unit = read("HermedBotsTests/CaptureSelectionTests.swift");
  assert.match(unit, /État inconnu/);
  assert.match(unit, /selectedRange\(\)\.length, 0\)/);
  assert.match(unit, /firstResponder === editor/);
});

test("le focus du compositeur de la #157 reste : ⏎ rend le premier répondant, la capture ne le retire pas", () => {
  const composer = read("HermedBots/Conversation/ComposerView.swift");
  const repair = firstBlock(composer, "private struct ComposerSubmitRepair");
  assert.match(repair, /makeFirstResponder/);
  assert.match(repair, /ComposerSubmit\.collapsedRange/);
  assert.match(composer, /\.onSubmit\(submit\)/);
  assert.match(firstBlock(composer, "private func submit"), /focused = true/);

  const app = read("HermedBots/App/HermedBotsApp.swift");
  assert.match(app, /if environment\.isTestMode/);
  assert.match(app, /CaptureSelection\.install\(\)/);

  const selection = read("HermedBots/Conversation/CaptureSelection.swift");
  assert.match(selection, new RegExp(REQUEST.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(selection, new RegExp(DONE.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  const install = firstBlock(selection, "static func install");
  assert.match(install, /collapseOpenEditors\(\)/);

  const project = read("HermedBots.xcodeproj/project.pbxproj");
  assert.match(project, /CaptureSelection\.swift in Sources/);
});
