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

test("un fil vide ne montre pas de tour terminé fantôme", () => {
  const conversation = read("HermedBots/Conversation/Conversation.swift");
  assert.match(
    conversation,
    /var showsEnd: Bool \{ end != nil && !entries\.isEmpty \}/,
    "showsEnd doit exiger des lignes : un transcript vide ne montre pas Tour terminé",
  );

  const view = read("HermedBots/Conversation/ConversationView.swift");
  const footer = firstBlock(view, "private var footer");
  assert.match(footer, /showsEnd/, "TurnEndRow suit showsEnd, pas la seule présence de end");
  assert.equal(
    /if let end = model\.conversation\.end \{/.test(footer),
    false,
    "un end orphelin ne doit plus poser TurnEndRow",
  );
});

test("le texte indicatif du compositeur reste sur un brouillon d'espaces", () => {
  const composer = read("HermedBots/Conversation/ComposerView.swift");
  assert.match(composer, /Conversation\.message\(from: model\.draft\) == nil/);
  assert.match(composer, /Écrire à \\\(bot\.name\)…/);
});

test("la dernière ligne du fil reste hors de la pile paresseuse", () => {
  const view = read("HermedBots/Conversation/ConversationView.swift");
  const transcript = firstBlock(view, "private var transcript");
  assert.match(transcript, /LazyVStack/);
  assert.match(transcript, /suffix\(1\)/);
  assert.match(transcript, /dropLast/);
  const lazyAt = transcript.indexOf("LazyVStack");
  const suffixAt = transcript.indexOf("suffix(1)");
  const footerAt = transcript.indexOf('footer.id("footer")');
  assert.notEqual(lazyAt, -1);
  assert.notEqual(suffixAt, -1);
  assert.notEqual(footerAt, -1);
  assert.ok(footerAt > lazyAt, "le pied reste sous la pile paresseuse");
  assert.match(transcript, /ForEach\(tail\)/);
});

test("hd09-blank part d'un fil vide, sans tour fantôme", () => {
  const source = read("HermedBotsUITests/SixActions.swift");
  const body = firstBlock(source, "func testAMessageOfSpacesCannotBeSent()");
  assert.match(body, /HVShot\.capture\("hd09-blank"/);
  assert.match(body, /sessionNew/);
  assert.match(body, /conversationEmpty/);
  assert.match(body, /conversationState/);
  assert.match(body, /XCTAssertFalse\(element\(\.conversationState/);
  const emptyAt = body.indexOf("conversationEmpty");
  const typeAt = body.indexOf('type("     "');
  const captureAt = body.indexOf('HVShot.capture("hd09-blank"');
  assert.ok(emptyAt !== -1 && emptyAt < typeAt, "Nouvelle session / fil vide avant les espaces");
  assert.ok(typeAt !== -1 && typeAt < captureAt, "les espaces précèdent la capture");
});

test("hd09-long attend la réponse assistant avant la capture", () => {
  const source = read("HermedBotsUITests/SixActions.swift");
  const body = firstBlock(source, "func testAHundredThousandCharacterMessageGoesOutOnce()");
  assert.match(body, /HVShot\.capture\("hd09-long"/);
  assert.match(body, /waitForMessage\(containing: "Réponse de test"/);
  const replyAt = body.indexOf('waitForMessage(containing: "Réponse de test"');
  const captureAt = body.indexOf('HVShot.capture("hd09-long"');
  assert.ok(replyAt !== -1 && replyAt < captureAt, "la réponse visible précède la capture");
});
