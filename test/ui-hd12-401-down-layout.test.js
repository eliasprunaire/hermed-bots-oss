"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const ERROR_TO_HALO = 16;

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

function conversationCovered(detail) {
  const start = detail.indexOf("ConversationView(");
  if (start === -1) return false;
  const close = matchingParen(detail, start + "ConversationView".length);
  if (close === -1) return false;
  return /^\s*\.overlay\([\s\S]*ErrorBanner/.test(detail.slice(close + 1, close + 181));
}

function homeBannerPushes(detail) {
  if (homeOverlayed(detail)) return false;
  const banner = detail.indexOf("ErrorBanner(model: model)");
  const home = detail.indexOf("HomeView(");
  if (banner === -1 || home === -1 || banner > home) return false;
  const shownGate = detail.search(/if shownBot != nil \{/);
  if (shownGate !== -1 && shownGate < banner) return false;
  return true;
}

function conversationPushed(detail) {
  if (conversationCovered(detail)) return false;
  const banner = detail.indexOf("ErrorBanner(model: model)");
  const conversation = detail.indexOf("ConversationView(");
  return banner !== -1 && conversation !== -1 && banner < conversation;
}

function producedHomeShift(bannerSource, appSource) {
  if (bannerCollapsed(bannerSource)) return 0;
  return homeBannerPushes(detailSource(appSource)) ? 1 : 0;
}

function producedRetryHittable(bannerSource) {
  return !bannerCollapsed(bannerSource);
}

function orbTopPadding(homeSource) {
  const home = firstBlock(homeSource, "struct HomeView");
  const start = home.indexOf("AuroraOrb(");
  assert.notEqual(start, -1, "AuroraOrb");
  const close = matchingParen(home, start + "AuroraOrb".length);
  const after = home.slice(close + 1, close + 80);
  const match = /^\s*\.padding\(\.top,\s*(\d+(?:\.\d+)?)/.exec(after);
  assert.ok(match, "AuroraOrb de l'accueil doit avoir un padding.top");
  return Number(match[1]);
}

test("accueil en erreur : le bandeau réserve sa hauteur, au moins 16 pt jusqu'au halo, Réessayer cliquable", () => {
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
  const home = read("HermedBots/Bots/HomeView.swift");
  const detail = detailSource(app);

  assert.equal(bannerCollapsed(banner), false, "hauteur nulle : Réessayer n'est plus cliquable");
  assert.equal(producedRetryHittable(banner), true);
  assert.equal(
    homeOverlayed(detail),
    false,
    "failed, missing-key, tunnel, unreachable, hd07-refuse-launch, hd12-401, hd12-down, hd12-video-000 : le bandeau ne doit pas être incrusté",
  );
  assert.equal(
    producedHomeShift(banner, app),
    1,
    "le bandeau d'erreur doit occuper de la hauteur de pile sur l'accueil",
  );
  assert.equal(
    conversationPushed(detail),
    true,
    "piste1-error et hd10-slow : le bandeau reste en pile, au-dessus de l'en-tête",
  );
  assert.equal(conversationCovered(detail), false, "le bandeau ne doit pas masquer l'en-tête de conversation");
  assert.ok(
    orbTopPadding(home) >= ERROR_TO_HALO,
    `moins de ${ERROR_TO_HALO} pt entre le haut de l'accueil et le halo`,
  );
  assert.equal(
    firstBlock(banner, "struct ErrorBanner").includes("ConnectingPill"),
    false,
    "ErrorBanner ne prend plus ConnectingPill pour modèle de hauteur nulle",
  );
});

test("un bandeau en pile sur l'accueil pousse l'orbe ; une incrustation ou une hauteur nulle ne le pousse pas", () => {
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
  const conversationOnly = [
    "struct ContentView {",
    "    var body: some View {",
    "        NavigationSplitView {",
    "            BotListView()",
    "        } detail: {",
    "            VStack(spacing: 0) {",
    "                if shownBot != nil {",
    "                    ErrorBanner(model: model)",
    "                }",
    "                HomeView()",
    "            }",
    "        }",
    "    }",
    "}",
    "",
  ].join("\n");
  assert.equal(producedHomeShift(occupying, stackedHome), 1);
  assert.equal(producedHomeShift(occupying, overlayHome), 0);
  assert.equal(producedHomeShift(occupying, conversationOnly), 0);
  assert.equal(producedHomeShift(collapsed, stackedHome), 0);
  assert.equal(producedRetryHittable(collapsed), false);
  assert.equal(producedRetryHittable(occupying), true);
});
