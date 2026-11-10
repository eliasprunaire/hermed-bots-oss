"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const SCHEME = "preferredColorScheme(model.testDarkAppearance ? .dark : nil)";
const UNAVAILABLE = "Liste des bots indisponible. Réessayez plus tard.";
const LONG_UNAVAILABLE = "Réessayez quand la liaison est rétablie.";

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

test("the sidebar failed state shows a short grey copy without interpolating the error or a second retry", () => {
  const view = read("HermedBots/Bots/BotListView.swift");
  const model = read("HermedBots/Bots/BotsModel.swift");
  assert.equal(model.includes(UNAVAILABLE), true);
  assert.equal(model.includes(LONG_UNAVAILABLE), false);
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

test("the About pane shows the Sparkle up-to-date copy only after a successful check, inside the card, in secondary color", () => {
  const check = read("Packages/HermesAdapter/Sources/UpdateCheck/UpdateCheck.swift");
  assert.match(check, /case idle/);
  assert.match(check, /state: UpdateCheckState = \.idle/);
  assert.match(check, /settled: UpdateCheckState = \.idle/);
  assert.match(check, /case \.idle: ""/);
  assert.doesNotMatch(check, /state: UpdateCheckState = \.upToDate/);
  assert.doesNotMatch(check, /settled: UpdateCheckState = \.upToDate/);

  const view = read("HermedBots/Settings/UpdatesSettingsView.swift");
  const bodyStart = view.indexOf("var body: some View {");
  const statusRowDef = view.indexOf("private var statusRow");
  assert.ok(bodyStart >= 0 && statusRowDef > bodyStart, "body/statusRow absents");
  const body = view.slice(bodyStart, statusRowDef);
  const form = (body.match(/Form \{[\s\S]*?\n        \}\n        \.formStyle\(\.grouped\)/) || [""])[0];
  assert.match(form, /statusRow/);
  assert.match(form, /SettingsCopy\.checkForUpdates/);
  const afterForm = body.split(".formStyle(.grouped)")[1] || "";
  assert.equal(afterForm.includes("statusRow"), false, afterForm);
  assert.equal(view.includes("foregroundStyle(.green)"), false);
  assert.match(view, /case \.idle:\s*\n\s*EmptyView\(\)/);
  assert.match(
    view,
    /case \.upToDate:[\s\S]*?Text\(UpdateCheckCopy\.upToDate\)[\s\S]*?foregroundStyle\(\.secondary\)/,
  );
});
