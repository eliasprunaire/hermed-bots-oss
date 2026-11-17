"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");

function read(rel) {
  return readFileSync(join(ROOT, rel), "utf8");
}

function blockEnd(source, marker) {
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
      if (depth === 0) return index;
    }
  }
  assert.fail(marker);
}

function firstBlock(source, marker) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, marker);
  return source.slice(start, blockEnd(source, marker) + 1);
}

function showsThinking(isBusy, isWaitingForUser, last) {
  if (!isBusy || isWaitingForUser) return false;
  if (last && last.role === "assistant" && last.text !== "") return false;
  return true;
}

test("le pied masque TypingDots et thinkingLabel dès que la réponse du bot a du texte", () => {
  const view = read("HermedBots/Conversation/ConversationView.swift");
  const footer = firstBlock(view, "private var footer");

  assert.match(footer, /if model\.isBusy/);
  assert.match(footer, /TypingDots/);
  assert.match(footer, /thinkingLabel/);
  assert.match(footer, /accessibilityID\(\.conversationBusy\)/);

  const busyAt = footer.indexOf("if model.isBusy");
  const typingAt = footer.indexOf("TypingDots");
  const thinkingAt = footer.indexOf("thinkingLabel");
  assert.notEqual(busyAt, -1);
  assert.notEqual(typingAt, -1);
  assert.notEqual(thinkingAt, -1);
  assert.ok(busyAt < typingAt, "TypingDots reste dans le pied occupé");
  assert.ok(busyAt < thinkingAt, "thinkingLabel reste dans le pied occupé");

  const beforeTyping = footer.slice(busyAt, typingAt);
  const gatesOnReplyText =
    /replyHasText/.test(beforeTyping) ||
    /text\.isEmpty/.test(beforeTyping) ||
    /role\s*!=\s*\.assistant/.test(beforeTyping);
  assert.ok(
    gatesOnReplyText,
    "TypingDots doit disparaître quand la dernière ligne du bot a déjà du texte",
  );

  const beforeThinking = footer.slice(busyAt, thinkingAt);
  const thinkingGated =
    /replyHasText/.test(beforeThinking) ||
    /text\.isEmpty/.test(beforeThinking) ||
    /role\s*!=\s*\.assistant/.test(beforeThinking);
  assert.ok(
    thinkingGated,
    "thinkingLabel doit disparaître quand la dernière ligne du bot a déjà du texte",
  );
});

test("les cas du premier jeton : indicateur avant le texte, masqué ensuite, curseur de flux conservé", () => {
  const view = read("HermedBots/Conversation/ConversationView.swift");
  const reply = firstBlock(view, "private var replyHasText");
  assert.match(reply, /last\.role == \.assistant/);
  assert.match(reply, /!last\.text\.isEmpty/);
  assert.match(firstBlock(view, "private var footer"), /isWaitingForUser \|\| !replyHasText/);

  assert.equal(
    showsThinking(true, false, { role: "user", text: "HV_SLOW go" }),
    true,
    "avant le premier jeton, le tour occupe encore l'écran",
  );
  assert.equal(
    showsThinking(true, false, { role: "assistant", text: "Début **gras encore ouvert" }),
    false,
    "dès le premier jeton, plus de « Le bot réfléchit… »",
  );
  assert.equal(showsThinking(true, false, { role: "assistant", text: "" }), true);
  assert.equal(showsThinking(true, false, null), true);
  assert.equal(showsThinking(true, true, { role: "assistant", text: "ok" }), false);
  assert.equal(showsThinking(false, false, { role: "assistant", text: "ok" }), false);

  const footer = firstBlock(view, "private var footer");
  const row = firstBlock(view, "private func messageRow");

  assert.match(
    row,
    /isStreaming:\s*model\.conversation\.phase == \.running && entry\.id == model\.conversation\.entries\.last\?\.id/,
    "le curseur de streaming suit la dernière ligne du tour, pas l'indicateur",
  );
  assert.match(view, /MessageMarkdownView\(source: entry\.text, selectable: !isStreaming, streaming: isStreaming\)/);
  assert.doesNotMatch(footer, /isStreaming/, "le pied occupé ne porte pas le curseur de flux");

  const busyChrome = footer.slice(footer.indexOf("if model.isBusy"));
  assert.match(busyChrome, /if model\.isWaitingForUser/);
  assert.match(busyChrome, /Le bot attend votre réponse/);
  assert.match(busyChrome, /if let tool = model\.currentTool/);
});

test("isBusy et les scènes hd09-busy / hd10-busy restent tels quels", () => {
  const model = read("HermedBots/Conversation/ConversationModel.swift");
  assert.match(
    model,
    /var isBusy: Bool \{ profileLockReason == nil && pauseCause == nil && machine\.shown\.step == \.sending \}/,
  );
  assert.doesNotMatch(read("HermedBots/Conversation/ConversationView.swift"), /var isBusy/);

  const six = read("HermedBotsUITests/SixActions.swift");
  const hd09 = firstBlock(six, "func testSendingWhileATurnRunsIsRefusedWithoutSendingAnythingExtra()");
  assert.match(hd09, /element\(\.conversationBusy/);
  assert.match(hd09, /HVShot\.capture\("hd09-busy"/);
  const busy09 = hd09.indexOf("conversationBusy");
  const capture09 = hd09.indexOf('HVShot.capture("hd09-busy"');
  assert.ok(busy09 !== -1 && busy09 < capture09, "hd09-busy attend encore hd.conversation.busy");

  const hd10 = firstBlock(six, "func testSwitchingWhileATurnRunsLeavesTheTurnAloneAndAppliesToTheNextOne()");
  assert.match(hd10, /element\(\.conversationBusy/);
  assert.match(hd10, /HVShot\.capture\("hd10-busy"/);
  const busy10 = hd10.indexOf("conversationBusy");
  const capture10 = hd10.indexOf('HVShot.capture("hd10-busy"');
  assert.ok(busy10 !== -1 && busy10 < capture10, "hd10-busy attend encore hd.conversation.busy");
  assert.match(hd10, /le tour tourne encore/);
  assert.match(hd10, /pickModel\("model-y"/);
  assert.match(hd10, /waitForModel\("model-y"/);
  assert.match(hd10, /le tour suivant part avec le modèle choisi/);

  const view = read("HermedBots/Conversation/ConversationView.swift");
  const footer = firstBlock(view, "private var footer");
  const chromeEnd = blockEnd(footer, "if model.isWaitingForUser || !replyHasText");
  const afterChrome = footer.slice(chromeEnd + 1);
  const toolAt = afterChrome.indexOf("if let tool = model.currentTool");
  assert.notEqual(toolAt, -1, "if let tool = model.currentTool");
  assert.match(
    afterChrome.slice(0, toolAt),
    /accessibilityID\(\.conversationBusy\)/,
    "hd.conversation.busy reste pendant .sending après le premier jeton",
  );
});
