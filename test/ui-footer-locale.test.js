"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const READY = "Prêt";
const VERSION_HERMES = "Version Hermes";

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

function catalogValue(catalog, key, locale) {
  const entry = catalog.strings[key];
  if (!entry) return key;
  const unit = entry.localizations?.[locale]?.stringUnit;
  if (unit?.state === "translated" && typeof unit.value === "string") return unit.value;
  if (locale === catalog.sourceLanguage) return key;
  return key;
}

function usesLocalizedLiteral(block, key) {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(String.raw`String\(localized:\s*"${escaped}"\)`).test(block)
    || new RegExp(String.raw`Text\("${escaped}"\)`).test(block);
}

function footerCopy(appSource, catalog, locale) {
  const footer = firstBlock(appSource, "private struct SidebarFooter");
  const readyLocalized = usesLocalizedLiteral(footer, READY)
    && !/Text\(verbatim:\s*"Prêt"\)/.test(footer);
  const versionLocalized = usesLocalizedLiteral(footer, VERSION_HERMES)
    && !/Text\(verbatim:\s*"Version Hermes"\)/.test(footer);
  return {
    ready: readyLocalized ? catalogValue(catalog, READY, locale) : READY,
    versionHermes: versionLocalized
      ? catalogValue(catalog, VERSION_HERMES, locale)
      : VERSION_HERMES,
  };
}

test("le pied affiche Prêt et Version Hermes en français, Ready et Hermes version en anglais", () => {
  const app = read("HermedBots/App/HermedBotsApp.swift");
  const catalog = JSON.parse(read("HermedBots/Resources/Localizable.xcstrings"));
  assert.equal(catalog.sourceLanguage, "fr");

  const french = footerCopy(app, catalog, "fr");
  assert.equal(french.ready, "Prêt");
  assert.equal(french.versionHermes, "Version Hermes");

  const english = footerCopy(app, catalog, "en");
  assert.equal(english.ready, "Ready");
  assert.equal(english.versionHermes, "Hermes version");
});
