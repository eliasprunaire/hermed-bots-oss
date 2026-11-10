"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const SCHEME = "preferredColorScheme(model.testDarkAppearance ? .dark : nil)";
const UNAVAILABLE = "Liste des bots indisponible. Réessayez quand la liaison est rétablie.";

function read(rel) {
  return readFileSync(join(ROOT, rel), "utf8");
}

function appliesScheme(text) {
  return text.includes(SCHEME);
}

function caseBody(source, label) {
  const marker = `case ${label}`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, marker);
  const rest = source.slice(start + 1);
  const next = rest.search(/\n        case /);
  assert.ok(next > 0, `${label} must be its own case`);
  return source.slice(start, start + 1 + next);
}

test("the Settings scene applies the same appearance override as the main window", () => {
  const app = read("HermedBots/App/HermedBotsApp.swift");
  const settings = read("HermedBots/Settings/SettingsWindow.swift");
  assert.ok(appliesScheme(app), "fenêtre principale sans réglage d'apparence");
  const scene = (app.match(/Settings \{[\s\S]*?\n        \}/) || [""])[0];
  assert.ok(scene.includes("SettingsWindow"), "scène Settings absente");
  assert.ok(
    appliesScheme(settings) || appliesScheme(scene),
    "la scène Réglages n'applique pas l'apparence de la fenêtre principale",
  );
  const combined = app + settings;
  assert.equal(combined.includes("NSApp.appearance"), false);
  assert.equal(settings.includes("Color.white"), false);
  assert.equal(settings.includes("Color.black"), false);
});

test("the sidebar failed state shows a fixed grey copy without interpolating the error or a second retry", () => {
  const view = read("HermedBots/Bots/BotListView.swift");
  const model = read("HermedBots/Bots/BotsModel.swift");
  assert.equal(model.includes(UNAVAILABLE), true);
  assert.match(view, /BotsModel\.listUnavailableMessage/);

  const failed = caseBody(view, ".failed");
  assert.equal(failed.includes("\\(message)"), false, failed);
  assert.equal(failed.includes("botsRetry"), false, failed);
  assert.equal(failed.includes("Réessayer"), false, failed);
  assert.match(failed, /foregroundStyle\(\.secondary\)/);
  assert.match(failed, /lineLimit\(2\)/);
  assert.match(failed, /accessibilityID\(\.botsError\)/);
  assert.match(failed, /listUnavailableMessage/);

  assert.match(model, /recordListFailure/);
  assert.match(model, /journalSink/);
});
