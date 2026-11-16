"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const HUGE = `HUGE-BEGIN ${"x".repeat(200_000)}`;
const LINE_HEIGHT = 16;
const CHARS_PER_LINE = 60;
const PARAMS_PADDING = 24;

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

function shownLimit(paramsSource) {
  const match = /static let limit = ([\d_]+)/.exec(paramsSource);
  assert.ok(match, "ApprovalParams.limit");
  return Number(match[1].replaceAll("_", ""));
}

function paramsMaxHeight(sheetSource) {
  const params = firstBlock(sheetSource, "private func params(");
  const match = /\.frame\(minHeight:\s*\d+,\s*maxHeight:\s*(\d+)\)/.exec(params);
  assert.ok(match, "maxHeight du bloc de paramètres");
  return Number(match[1]);
}

function producedShown(command, limit) {
  return command.slice(0, limit);
}

function producedOverflow(command, limit, maxHeight) {
  const shown = producedShown(command, limit);
  const innerHeight = maxHeight - PARAMS_PADDING;
  const contentHeight = Math.ceil(shown.length / CHARS_PER_LINE) * LINE_HEIGHT;
  return contentHeight > innerHeight;
}

test("hd11-huge-params : le texte montré tient dans le cadre, sans défilement entre deux passes", () => {
  const paramsSource = read("HermedBots/Approval/ApprovalParams.swift");
  const sheetSource = read("HermedBots/Approval/ApprovalSheet.swift");
  const limit = shownLimit(paramsSource);
  const maxHeight = paramsMaxHeight(sheetSource);
  const shown = producedShown(HUGE, limit);

  assert.ok(shown.startsWith("HUGE-BEGIN "), shown.slice(0, 40));
  assert.ok(shown.length < HUGE.length, "la feuille doit marquer une coupure");
  assert.equal(
    producedOverflow(HUGE, limit, maxHeight),
    false,
    `limit=${limit} maxHeight=${maxHeight} : le bloc défile encore`,
  );
});

test("un texte de 50 000 caractères défile encore dans le cadre de 260 pt", () => {
  const sheetSource = read("HermedBots/Approval/ApprovalSheet.swift");
  const maxHeight = paramsMaxHeight(sheetSource);
  assert.equal(producedOverflow(HUGE, 50_000, maxHeight), true);
  assert.equal(producedOverflow(HUGE, 480, maxHeight), false);
});

test("HD-11 et son scénario UI ne promettent plus un défilement", () => {
  const sixFile = read("HermedBotsUITests/SixActions.swift");
  const six = firstBlock(sixFile, "func testAHugeParameter");
  const sheet = read("HermedBots/Approval/ApprovalSheet.swift");
  const plan = read("docs/plans/hermed-bots.md");
  const feature = read(".cursor/skills/verify-hermed-bots/features/approval.md");
  assert.match(sixFile, /testAHugeParameterIsBoundedAndMarksWhatItDoesNotShow/);
  assert.match(sixFile, /le texte montré est borné/);
  assert.equal(/scroll\(/.test(six), false);
  assert.equal(/défile/.test(six), false);
  assert.equal(/Les paramètres défilent/.test(sheet), false);
  assert.match(sheet, /Les paramètres sont bornés/);
  assert.equal(/sheet scrolls/.test(plan), false);
  assert.match(plan, /sheet bounds the shown text/);
  assert.equal(/feuille défilante/.test(feature), false);
  assert.match(feature, /texte borné/);
});
