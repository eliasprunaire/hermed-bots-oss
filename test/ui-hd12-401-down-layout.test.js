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

function matchingParen(source, open) {
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    const char = source[index];
    if (char === "(") depth += 1;
    else if (char === ")") {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

function detailSource(appSource) {
  const content = firstBlock(appSource, "struct ContentView");
  return firstBlock(content, "} detail: ");
}

function bannerCollapsed(bannerSource) {
  const banner = firstBlock(bannerSource, "struct ErrorBanner");
  return /\.frame\([^)]*\b(?:maxHeight|height):\s*0/.test(banner);
}

function homeOverlayed(detail) {
  const start = detail.indexOf("HomeView(");
  if (start === -1) return false;
  const close = matchingParen(detail, start + "HomeView".length);
  if (close === -1) return false;
  return /^\s*\.overlay\([\s\S]*ErrorBanner\(model: model\)/.test(detail.slice(close + 1, close + 181));
}

function conversationStacked(detail) {
  return /if shownBot != nil \{\s*ErrorBanner\(model: model\)/.test(detail);
}

function conversationCovered(detail) {
  const start = detail.indexOf("ConversationView(");
  if (start === -1) return false;
  const close = matchingParen(detail, start + "ConversationView".length);
  if (close === -1) return false;
  return /^\s*\.overlay\([\s\S]*ErrorBanner/.test(detail.slice(close + 1, close + 181));
}

function producedHomeShift(bannerSource, appSource) {
  if (bannerCollapsed(bannerSource)) return 0;
  const detail = detailSource(appSource);
  if (homeOverlayed(detail)) return 0;
  if (/ErrorBanner\(model: model\)/.test(detail)) return 1;
  return 0;
}

function producedRetryHittable(bannerSource) {
  return !bannerCollapsed(bannerSource);
}

test("hd12-401 et hd12-down : bandeau incrusté sur l'accueil, Réessayer cliquable, en-tête de conversation visible", () => {
  const errors = read("HermedBotsUITests/Errors.swift");
  const down = firstBlock(errors, "func testApiUnreachable");
  const refused = firstBlock(errors, "func testRefusedKey");
  const retry = firstBlock(errors, "func testRetry");
  const recovery = firstBlock(errors, "func testRecordedRecovery");
  assert.match(down, /hd12-down/);
  assert.match(down, /hd\.banner\.error/);
  assert.match(refused, /hd12-401/);
  assert.match(refused, /hd\.banner\.error/);
  assert.match(retry, /hd\.banner\.error\.retry/);
  assert.match(recovery, /hd\.banner\.error\.retry/);

  const banner = read("HermedBots/Banners/ErrorBanner.swift");
  const app = read("HermedBots/App/HermedBotsApp.swift");
  const detail = detailSource(app);

  assert.equal(bannerCollapsed(banner), false, "hauteur nulle : Réessayer n'est plus cliquable");
  assert.equal(producedRetryHittable(banner), true);
  assert.equal(
    producedHomeShift(banner, app),
    0,
    "le bandeau d'erreur occupe de la hauteur de pile et décale l'accueil (scrollbar, cartes hors pied)",
  );
  assert.equal(homeOverlayed(detail), true, "l'accueil doit incruster le bandeau");
  assert.equal(conversationStacked(detail), true, "en conversation le bandeau reste en pile, au-dessus de l'en-tête");
  assert.equal(conversationCovered(detail), false, "le bandeau ne doit pas masquer l'en-tête de conversation");
  assert.equal(
    firstBlock(banner, "struct ErrorBanner").includes("ConnectingPill"),
    false,
    "ErrorBanner ne prend plus ConnectingPill pour modèle de hauteur nulle",
  );
});

test("un bandeau en pile sur l'accueil décale les cartes ; une hauteur nulle rend Réessayer inaccessible", () => {
  const occupying =
    "struct ErrorBanner {\n    var body: some View {\n        NoticeCard(tint: .orange, symbol: \"x\") { Text(\"err\") }\n    }\n}\n";
  const collapsed =
    "struct ErrorBanner {\n    var body: some View {\n        NoticeCard(tint: .orange, symbol: \"x\") { Text(\"err\") }\n            .frame(height: 0, alignment: .top)\n    }\n}\n";
  const stackedHome = [
    "struct ContentView {",
    "    var body: some View {",
    "        NavigationSplitView {",
    "            BotListView()",
    "        } detail: {",
    "            VStack(spacing: 0) {",
    "                ErrorBanner(model: model)",
    "                HomeView()",
    "            }",
    "        }",
    "    }",
    "}",
    "",
  ].join("\n");
  const overlayHome = [
    "struct ContentView {",
    "    var body: some View {",
    "        NavigationSplitView {",
    "            BotListView()",
    "        } detail: {",
    "            VStack(spacing: 0) {",
    "                HomeView()",
    "                    .overlay(alignment: .top) { ErrorBanner(model: model) }",
    "            }",
    "        }",
    "    }",
    "}",
    "",
  ].join("\n");
  assert.equal(producedHomeShift(occupying, stackedHome), 1);
  assert.equal(producedHomeShift(occupying, overlayHome), 0);
  assert.equal(producedHomeShift(collapsed, stackedHome), 0);
  assert.equal(producedRetryHittable(collapsed), false);
  assert.equal(producedRetryHittable(occupying), true);
});
