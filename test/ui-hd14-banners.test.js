"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const TECHNICAL = "détection Desktop indisponible";
const HELD = "Hermes Desktop tient ce profil. Libérez-le dans Desktop avant de continuer.";
const DEGRADED =
  "Mode dégradé : la détection de Hermes Desktop est indisponible. Les écritures de ce profil sont bloquées.";
const CAUSE = "Cause : hôte injoignable. Vérifiez le réseau, puis réessayez.";
const PILL_HELD = "Tenu par Desktop";
const PILL_DEGRADED = "Dégradé";

const VIEW_FILES = [
  "HermedBots/Conversation/ConversationView.swift",
  "HermedBots/Bots/BotListView.swift",
  "HermedBots/Bots/HomeView.swift",
  "HermedBots/Bots/BotLockPill.swift",
  "HermedBots/Banners/DegradedBanner.swift",
  "HermedBots/Banners/ErrorBanner.swift",
  "HermedBots/Approval/ApprovalSheet.swift",
];

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

test("l'état tenu n'a qu'un bandeau, l'orange à cadenas, pas le rouge doublon", () => {
  const view = read("HermedBots/Conversation/ConversationView.swift");
  const model = read("HermedBots/Conversation/ConversationModel.swift");
  const lock = firstBlock(view, "if let reason = model.profileLockReason");
  assert.match(lock, /NoticeCard\(tint: \.orange, symbol: "lock\.fill"\)/);
  assert.match(lock, /accessibilityID\(\.profileLock\)/);
  assert.equal(lock.includes("exclamationmark.triangle"), false, lock);

  assert.match(model, /var displayedOpenError: String\?/);
  assert.match(model, /var displayedFailure: String\?/);
  assert.match(model, /var lockAndErrorBannerCount: Int/);
  assert.match(view, /if let error = model\.displayedOpenError/);
  assert.match(view, /if let failure = model\.displayedFailure/);
  assert.equal(view.includes("if let error = model.openError"), false);
  assert.equal(view.includes("if let failure = model.conversation.failure"), false);
});

test("le bandeau dégradé a les deux phrases et jamais la ligne technique brute", () => {
  const lock = read("HermedBots/Transport/ProfileLock.swift");
  assert.match(lock, new RegExp(DEGRADED.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(lock, /hôte injoignable\. Vérifiez le réseau, puis réessayez\./);
  assert.match(lock, /String\(localized: "Cause : \\\(cause\)"\)/);
  assert.equal(lock.includes(TECHNICAL), false, "la ligne brute ne doit pas vivre dans le verrou");
  assert.match(lock, /case \.unreachable/);

  for (const file of VIEW_FILES) {
    const source = read(file);
    assert.equal(source.includes(TECHNICAL), false, file);
  }
});

test("la barre latérale affiche les pastilles courtes, pas le texte long du bandeau", () => {
  const lock = read("HermedBots/Transport/ProfileLock.swift");
  const row = read("HermedBots/Bots/BotListView.swift");
  const pillView = read("HermedBots/Bots/BotLockPill.swift");
  const ui = read("HermedBotsUITests/ConcurrencyTests.swift");
  assert.match(lock, new RegExp(`"${PILL_HELD}"`));
  assert.match(lock, new RegExp(`"${PILL_DEGRADED}"`));
  assert.match(row, /profileLock\.sidebarLabel\(bot\.id\)/);
  assert.match(row, /lockLabel:/);
  const pill = firstBlock(row, "if let lockLabel");
  assert.match(pill, /BotLockPill\(/);
  assert.match(pill, /accessibilityID: AccessibilityID\.botLock\(bot\.id\)/);
  assert.equal(pill.includes("Text(lockReason)"), false, pill);
  assert.equal(pill.includes(HELD), false, pill);
  assert.equal(row.includes("Mode dégradé : la détection"), false);
  assert.match(pillView, /Text\(label\)/);
  assert.match(pillView, /\.help\(help\)/);
  assert.match(pillView, /\.fixedSize\(\)/);
  assert.match(ui, /Tenu par Desktop/);
  assert.equal(ui.includes('text(reason).contains("Hermes Desktop")'), false);
});
