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

test("hd11-current-tool capture hd.tool.current, pas Outil terminé", () => {
  const six = firstBlock(read("HermedBotsUITests/SixActions.swift"), "func testCurrentTool");
  const existsAt = six.indexOf("waitForExistence");
  const captureAt = six.indexOf('HVShot.capture("hd11-current-tool"');
  const goneAt = six.indexOf("waitForNonExistence");
  const finishedAt = six.indexOf("Outil terminé");
  assert.notEqual(existsAt, -1, "waitForExistence de l'outil");
  assert.notEqual(captureAt, -1, "capture hd11-current-tool");
  assert.ok(existsAt < captureAt, "hd.tool.current est présent avant la capture");
  assert.ok(captureAt !== -1 && captureAt < goneAt, "la disparition de l'outil vient après la capture");
  assert.ok(captureAt !== -1 && captureAt < finishedAt, "Outil terminé n'est pas l'état capturé");
  assert.match(six.slice(existsAt, captureAt), /toolCurrent|hd\.tool\.current/);
  assert.doesNotMatch(six.slice(0, captureAt), /Outil terminé/);

  const shot = firstBlock(read("HermedBotsUITests/HVShot.swift"), "enum HVShot");
  const capture = firstBlock(shot, "static func capture(_ name: String, _ window: XCUIElement)");
  const shotCall = capture.indexOf("window.screenshot()");
  assert.notEqual(shotCall, -1);
  const before = capture.slice(0, shotCall);
  assert.match(before, /hd11-current-tool/);
  assert.match(before, /hd\.tool\.current/);
  assert.match(before, /waitUntilPresent/);
  assert.doesNotMatch(before, /Outil terminé/);
  assert.doesNotMatch(before, /waitForExistence/);
  assert.doesNotMatch(shot, /XCTNSPredicateExpectation/);

  const hd11 = firstBlock(capture, 'if name == "hd11-current-tool"');
  assert.match(hd11, /collapseBeforeCapture\(\)/);
  assert.match(hd11, /hd\.tool\.current/);
  assert.match(hd11, /waitUntilPresent/);
  assert.doesNotMatch(hd11, /parkPointer/);
  assert.doesNotMatch(hd11, /\.hover\(/);
  assert.doesNotMatch(hd11, /Outil terminé/);

  const park = firstBlock(shot, "static func parkPointer");
  assert.match(park, /neutralPointerOffset/);
  assert.match(park, /\.hover\(\)/);
  assert.doesNotMatch(park, /addingTimeInterval/);
  assert.doesNotMatch(park, /RunLoop/);
  assert.doesNotMatch(park, /sleep/);

  const wait = firstBlock(shot, "static func waitUntilPresent");
  assert.match(wait, /\.exists/);
  assert.match(wait, /addingTimeInterval/);
});
