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
    const char = source[index];
    if (char === "{") depth += 1;
    else if (char === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  assert.fail(marker);
}

test("la barre compacte priorise Nouvelle session et place Tout arrêter en premier dans le débordement", () => {
  const app = read("HermedBots/App/HermedBotsApp.swift");
  const conversation = read("HermedBots/Conversation/ConversationView.swift");
  const stop = read("HermedBots/KillSwitch/StopAllButton.swift");

  const sessionBar = firstBlock(conversation, ".toolbar {");
  assert.match(sessionBar, /accessibilityID\(\.sessionNew\)/);
  assert.match(sessionBar, /Nouvelle session/);
  assert.match(sessionBar, /square\.and\.pencil/);
  assert.match(sessionBar, /visibilityPriority\(\.high\)/);
  assert.match(sessionBar, /\.labelStyle\(\.titleAndIcon\)/);
  assert.match(sessionBar, /\.labelStyle\(\.iconOnly\)/);
  assert.equal(sessionBar.includes("StopAllButton"), false);
  assert.equal(sessionBar.includes("ToolbarOverflowMenu"), false);

  const windowBar = firstBlock(app, ".toolbar {");
  assert.match(windowBar, /StopAllButton\(model: model\.killSwitch\)/);
  assert.match(windowBar, /visibilityPriority\(\.low\)/);
  assert.equal(windowBar.includes("ToolbarOverflowMenu"), false);
  assert.equal(windowBar.includes(".sessionNew"), false);

  assert.match(stop, /\.help\(model\.message\)/);
  assert.match(stop, /accessibilityID\(inApproval \? \.approvalStopAll : \.stopAll\)/);
  assert.match(stop, /Button\(role: \.destructive\) \{ Task \{ await model\.stopAll\(\) \} \}/);
  assert.match(conversation, /StopAllButton\(model: killSwitch, inApproval: true\)/);
});
