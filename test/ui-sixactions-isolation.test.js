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

test("testListBots lance un processus neuf et capture l'accueil, pas un fil ouvert", () => {
  const source = read("HermedBotsUITests/SixActions.swift");
  const body = firstBlock(source, "func testListBots()");
  assert.match(body, /HVShot\.capture\("hd08-bots"/);
  assert.equal(body.includes("launch(isolated: false)"), false);
  assert.match(body, /let app = launch\(\)/);
  assert.match(body, /AccessibilityID\.homeBot\("hv-bot-a"\)/);
  assert.match(body, /element\(\.conversationView, in: app\)\.exists/);
  assert.match(body, /XCTAssertFalse\(element\(\.conversationView, in: app\)\.exists/);
});

test("testReopeningAThread rétablit les fixtures du faux serveur avant le lancement", () => {
  const source = read("HermedBotsUITests/SixActions.swift");
  const body = firstBlock(source, "func testReopeningAThreadShowsItsTranscriptAndSendsNothing()");
  const resetAt = body.indexOf("FakeServer.reset()");
  const launchAt = body.indexOf("launch()");
  assert.notEqual(resetAt, -1, "FakeServer.reset() absent");
  assert.notEqual(launchAt, -1, "launch() absent");
  assert.ok(resetAt < launchAt, "reset() doit précéder launch()");
  assert.match(body, /\["Bonjour", "Réponse de test"\]/);
});

function pythonDef(source, name) {
  const marker = `def ${name}(`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, marker);
  const rest = source.slice(start);
  const next = rest.search(/\n(?:def |[A-Z_][A-Z0-9_]* = )/);
  return next === -1 ? rest : rest.slice(0, next);
}

test("POST /_hv/reset resème les transcripts des sessions", () => {
  const source = read(".cursor/skills/verify-hermed-bots/scripts/hv-fake-hermes.py");
  const reset = pythonDef(source, "reset_state");
  assert.match(reset, /seed_session_messages\(\)/);
  const seed = pythonDef(source, "seed_session_messages");
  assert.match(seed, /SESSION_MSGS\.clear\(\)/);
  assert.match(seed, /SEED_MSG_DATA/);
});
