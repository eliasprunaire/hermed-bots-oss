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
  assert.match(reset, /fail_without_text=False/);
  const seed = pythonDef(source, "seed_session_messages");
  assert.match(seed, /SESSION_MSGS\.clear\(\)/);
  assert.match(seed, /SEED_MSG_DATA/);
});

test("testEveryTerminalState active le mode échec sans texte avant chaque capture hd09", () => {
  const source = read("HermedBotsUITests/SixActions.swift");
  const body = firstBlock(source, "func testEveryTerminalStateShowsAsHermesSentIt()");
  const configAt = body.indexOf("failWithoutText: true");
  const injectAt = body.indexOf("serverPost(\"/_hv/inject\"");
  const captureAt = body.indexOf("HVShot.capture");
  assert.notEqual(configAt, -1, "failWithoutText absent");
  assert.notEqual(injectAt, -1, "inject absent");
  assert.notEqual(captureAt, -1, "capture absente");
  assert.ok(configAt < injectAt, "le mode doit précéder l'injection");
  assert.ok(injectAt < captureAt, "l'injection doit précéder la capture");
  for (const shot of ["hd09-failed", "hd09-failed-error", "hd09-cancelled", "hd09-interrupted"]) {
    assert.match(body, new RegExp(`"${shot}"`));
  }
  assert.match(body, /Réponse de t/);
  assert.match(body, /aucun texte assistant pour l'échec/);
});

test("les autres scénarios hd09 n'activent pas le mode échec sans texte", () => {
  const source = read("HermedBotsUITests/SixActions.swift");
  const others = [
    "func testConversation()",
    "func testAnUnknownEventInTheStreamDoesNotBreakTheTurn()",
    "func testReopeningAThreadShowsItsTranscriptAndSendsNothing()",
  ];
  for (const marker of others) {
    const body = firstBlock(source, marker);
    assert.equal(body.includes("failWithoutText"), false, marker);
    assert.equal(body.includes("fail_without_text"), false, marker);
  }
});
