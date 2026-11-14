"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const VERSION_HERMES = "Version Hermes";
const UNKNOWN = "inconnue";
const READY = "Prêt";
const CONNECTING = "Connexion…";
const UNTESTED = "Compatibilité · voir Réglages";

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

function footerLine(...segments) {
  return segments
    .flatMap((segment) => String(segment).trim().split(/\s+/u))
    .filter((part) => part.length > 0)
    .join(" ");
}

function producedVersionLine(appSource, footer, catalog, locale, token) {
  const label = usesLocalizedLiteral(footer, VERSION_HERMES)
    ? catalogValue(catalog, VERSION_HERMES, locale)
    : VERSION_HERMES;
  const unknown = usesLocalizedLiteral(appSource, UNKNOWN)
    ? catalogValue(catalog, UNKNOWN, locale)
    : UNKNOWN;
  const value = token === undefined ? unknown : token;
  if (/FooterCopy\.line\(/.test(footer)) return footerLine(label, value);
  // Deux Text (libellé puis jeton) : l'écart du HStack se lit comme un double espace.
  return `${label}  ${value}`;
}

function assertClean(text, detail) {
  assert.equal(text, text.trim(), detail);
  assert.ok(!text.includes("  "), detail);
}

test("le pied produit Version Hermes inconnue sans double espace, en français et en anglais", () => {
  const app = read("HermedBots/App/HermedBotsApp.swift");
  const catalog = JSON.parse(read("HermedBots/Resources/Localizable.xcstrings"));
  const footer = firstBlock(app, "private struct SidebarFooter");
  assert.equal(catalog.sourceLanguage, "fr");

  const frenchUnknown = producedVersionLine(app, footer, catalog, "fr");
  assert.equal(frenchUnknown, "Version Hermes inconnue");
  assertClean(frenchUnknown, "fr inconnue");

  const englishUnknown = producedVersionLine(app, footer, catalog, "en");
  assert.equal(englishUnknown, "Hermes version unknown");
  assertClean(englishUnknown, "en unknown");

  const frenchEmpty = producedVersionLine(app, footer, catalog, "fr", "");
  assert.equal(frenchEmpty, "Version Hermes");
  assertClean(frenchEmpty, "fr vide");

  const englishEmpty = producedVersionLine(app, footer, catalog, "en", "  ");
  assert.equal(englishEmpty, "Hermes version");
  assertClean(englishEmpty, "en vide");

  const frenchSpaced = producedVersionLine(app, footer, catalog, "fr", "  0.22.2  ");
  assert.equal(frenchSpaced, "Version Hermes 0.22.2");
  assertClean(frenchSpaced, "fr version espacée");

  const englishSpaced = producedVersionLine(app, footer, catalog, "en", "  0.22.2  ");
  assert.equal(englishSpaced, "Hermes version 0.22.2");
  assertClean(englishSpaced, "en version espacée");
});

test("les chaînes du pied n'ont ni double espace ni espace en bord, en français et en anglais", () => {
  const catalog = JSON.parse(read("HermedBots/Resources/Localizable.xcstrings"));
  for (const key of [VERSION_HERMES, UNKNOWN, READY, CONNECTING, UNTESTED]) {
    for (const locale of ["fr", "en"]) {
      const value = catalogValue(catalog, key, locale);
      assertClean(value, `${locale} ${key}`);
    }
  }
});
