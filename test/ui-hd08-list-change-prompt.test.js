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

function listBlock(body) {
  const start = body.search(/\bList\s*\{/);
  if (start === -1) return "";
  const open = body.indexOf("{", start);
  let depth = 0;
  for (let index = open; index < body.length; index += 1) {
    const char = body[index];
    if (char === "{") depth += 1;
    else if (char === "}") {
      depth -= 1;
      if (depth === 0) return body.slice(start, index + 1);
    }
  }
  return "";
}

function producedNoticeAboveList(body) {
  const noticeAt = body.indexOf("BotChangeNotice(");
  const listAt = body.search(/\bList\s*\{/);
  if (noticeAt === -1 || listAt === -1) return false;
  const list = listBlock(body);
  return noticeAt < listAt && !list.includes("BotChangeNotice(");
}

function overlayCoversNotice(body) {
  const noticeAt = body.indexOf("BotChangeNotice(");
  const overlayAt = body.indexOf(".overlay { placeholder }");
  if (noticeAt === -1 || overlayAt === -1) return true;
  const listAt = body.search(/\bList\s*\{/);
  return noticeAt > listAt && noticeAt < overlayAt;
}

test("hd08-list-change-prompt : la carte d'invite est au-dessus de la List, pas une ligne ForEach", () => {
  const view = read("HermedBots/Bots/BotListView.swift");
  const body = firstBlock(view, "struct BotListView");
  assert.match(body, /BotChangeNotice\(/);
  assert.match(body, /model\.list\.change/);
  assert.match(body, /model\.validateChange/);
  assert.equal(
    producedNoticeAboveList(body),
    true,
    "la carte est une ligne de List : ForEach aux mêmes identifiants ne l'insère pas",
  );
  assert.equal(
    overlayCoversNotice(body),
    false,
    "l'overlay de List recouvre la carte d'invite",
  );
  assert.match(body, /VStack\(spacing: 0\)/);
  assert.doesNotMatch(listBlock(body), /BotChangeNotice\(/);

  const notice = firstBlock(view, "struct BotChangeNotice");
  assert.match(notice, /BotChangeNoticeContent\(change: change\)/);
  assert.match(notice, /accessibilityID\(\.botsChange\)/);
  assert.match(notice, /accessibilityID\(\.botsChangeApply\)/);
  assert.match(notice, /accessibilityElement\(children: \.contain\)/);
  assert.match(notice, /content\.title/);
  assert.match(notice, /content\.apply/);

  const content = firstBlock(read("HermedBots/Bots/BotList.swift"), "struct BotChangeNoticeContent");
  assert.match(content, /La liste des bots a changé/);
  assert.match(content, /Afficher la nouvelle liste/);
  assert.match(content, /Ajouté :/);
  assert.match(content, /Retiré :/);

  const unit = read("HermedBotsTests/BotListTests.swift");
  assert.match(unit, /testAPendingAdditionProducesTheSidebarNoticeCopyWhileShownStaysPut/);
  assert.match(unit, /La liste des bots a changé/);
  assert.match(unit, /Ajouté : hv-new/);
  assert.match(unit, /Afficher la nouvelle liste/);
});

test("une carte dans la List disparaît quand le ForEach garde les mêmes identifiants", () => {
  const stacked = [
    "var body: some View {",
    "    List {",
    "        if let change = model.list.change {",
    "            BotChangeNotice(change: change, apply: model.validateChange)",
    "        }",
    "        ForEach(model.list.shown ?? []) { bot in",
    "            BotRow(bot: bot)",
    "        }",
    "    }",
    "    .overlay { placeholder }",
    "}",
    "",
  ].join("\n");
  const above = [
    "var body: some View {",
    "    VStack(spacing: 0) {",
    "        if let change = model.list.change {",
    "            BotChangeNotice(change: change, apply: model.validateChange)",
    "        }",
    "        List {",
    "            ForEach(model.list.shown ?? []) { bot in",
    "                BotRow(bot: bot)",
    "            }",
    "        }",
    "        .overlay { placeholder }",
    "    }",
    "}",
    "",
  ].join("\n");
  assert.equal(producedNoticeAboveList(stacked), false);
  assert.equal(overlayCoversNotice(stacked), true);
  assert.equal(producedNoticeAboveList(above), true);
  assert.equal(overlayCoversNotice(above), false);
});
