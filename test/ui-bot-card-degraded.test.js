"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const DEGRADED =
  "Mode dégradé : la détection de Hermes Desktop est indisponible. Les écritures de ce profil sont bloquées.";
const PILL_DEGRADED = "Dégradé";

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

// Contenu produit de la carte en mode dégradé : le modèle, la pastille, l'aide — jamais le texte du bandeau.
function degradedCardCopy() {
  const model = "demo";
  const lockLabel = PILL_DEGRADED;
  const lockHelp = DEGRADED;
  return {
    subtitle: model,
    lockLabel,
    lockHelp,
  };
}

test("en mode dégradé la carte produit le modèle, la pastille Dégradé et l'aide, pas le texte Mode dégradé", () => {
  const produced = degradedCardCopy();
  assert.equal(produced.subtitle, "demo");
  assert.equal(produced.lockLabel, "Dégradé");
  assert.match(produced.lockHelp, /la détection de Hermes/);
  assert.equal(produced.subtitle.includes("Mode dégradé"), false);
  assert.equal(produced.lockHelp.includes(produced.subtitle), false);

  const card = firstBlock(read("HermedBots/Bots/HomeView.swift"), "struct BotCard");
  assert.equal(card.includes("Text(lockReason)"), false, "la carte affiche encore le texte du bandeau");
  assert.equal(card.includes("Mode dégradé"), false);
  assert.match(card, /BotCardContent\(bot: bot, lockLabel:/);
  assert.match(card, /content\.subtitle/);
  assert.match(card, /BotLockPill\(/);
  assert.match(card, /help: content\.lockHelp/);

  const swift = read("HermedBotsTests/BotCardContentTests.swift");
  assert.match(swift, /content\.subtitle, "demo"/);
  assert.match(swift, /content\.lockLabel, "Dégradé"/);
  assert.match(swift, /la détection de Hermes/);
  assert.match(swift, /Mode dégradé/);
  assert.equal(swift.includes("Text(lockReason)"), false);

  const content = firstBlock(read("HermedBots/Bots/BotList.swift"), "struct BotCardContent");
  const init = firstBlock(content, "init(bot:");
  assert.match(init, /subtitle = model/);
  assert.equal(init.includes("subtitle = lockHelp"), false);
  assert.equal(init.includes("subtitle = lockLabel"), false);
  assert.match(init, /self\.lockLabel = lockLabel/);
  assert.match(init, /self\.lockHelp = lockHelp/);
});

test("état inconnu : aucune pastille ; dégradation constatée : pastille Dégradé ; état sain : aucune pastille", () => {
  const unknown = { subtitle: "demo", lockLabel: null, lockHelp: null };
  const degraded = degradedCardCopy();
  const healthy = { subtitle: "demo", lockLabel: null, lockHelp: null };
  assert.equal(unknown.lockLabel, null);
  assert.equal(unknown.lockHelp, null);
  assert.equal(degraded.lockLabel, "Dégradé");
  assert.match(degraded.lockHelp, /la détection de Hermes/);
  assert.equal(healthy.lockLabel, null);
  assert.equal(healthy.lockHelp, null);

  const lock = read("HermedBots/Transport/ProfileLock.swift");
  const sidebarLabel = firstBlock(lock, "var sidebarLabel: String?");
  assert.match(sidebarLabel, /case \.free, \.unknown: nil/);
  assert.match(sidebarLabel, /case \.degraded: String\(localized: "Dégradé"\)/);
  const reason = firstBlock(lock, "var reason: String?");
  assert.match(reason, /case \.free, \.unknown: nil/);
  assert.match(reason, /case \.degraded: String\(localized: "Mode dégradé/);

  const swift = read("HermedBotsTests/BotCardContentTests.swift");
  assert.match(swift, /testUnknownLockHasNoPillObservedDegradationShowsDegradedAndHealthyHasNone/);
  assert.match(swift, /shownState\(bot\.id\), \.unknown/);
  assert.match(swift, /shownState\(bot\.id\), \.degraded/);
  assert.match(swift, /shownState\(bot\.id\), \.free/);
  assert.match(swift, /XCTAssertNil\(content\.lockLabel\)/);
  assert.match(swift, /XCTAssertNil\(lock\.sidebarLabel\(bot\.id\)\)/);
  assert.match(swift, /content\.lockLabel, "Dégradé"/);
});

test("l'écran banner-degraded de la piste 1 a un nom assez long pour se tronquer à côté de la pastille", () => {
  const app = read("HermedBots/App/AppModel.swift");
  const start = app.indexOf("case .bannerDegraded:");
  assert.notEqual(start, -1);
  const next = app.indexOf("case .", start + 1);
  const scene = app.slice(start, next);
  assert.match(scene, /tronquer/);
  assert.match(scene, /pastille/);
  assert.match(scene, /seedDegraded/);
});
