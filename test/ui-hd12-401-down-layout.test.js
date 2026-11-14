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

function bannerInDetailStack(appSource) {
  const content = firstBlock(appSource, "struct ContentView");
  const detail = firstBlock(content, "} detail: ");
  return /ErrorBanner\(model: model\)/.test(detail);
}

function bannerCollapsed(bannerSource) {
  const banner = firstBlock(bannerSource, "struct ErrorBanner");
  return /\.frame\([^)]*\b(?:maxHeight|height):\s*0/.test(banner);
}

function producedHomeShift(bannerSource, appSource) {
  if (!bannerInDetailStack(appSource)) return 0;
  if (bannerCollapsed(bannerSource)) return 0;
  return 1;
}

test("hd12-401 et hd12-down : le bandeau d'erreur ne pousse pas l'accueil hors du pied", () => {
  const errors = read("HermedBotsUITests/Errors.swift");
  const down = firstBlock(errors, "func testApiUnreachable");
  const refused = firstBlock(errors, "func testRefusedKey");
  assert.match(down, /hd12-down/);
  assert.match(down, /hd\.banner\.error/);
  assert.match(refused, /hd12-401/);
  assert.match(refused, /hd\.banner\.error/);

  const shift = producedHomeShift(
    read("HermedBots/Banners/ErrorBanner.swift"),
    read("HermedBots/App/HermedBotsApp.swift"),
  );
  assert.equal(
    shift,
    0,
    "le bandeau d'erreur occupe de la hauteur de pile et décale l'accueil (scrollbar, cartes hors pied)",
  );
});

test("un bandeau qui garde sa hauteur de pile décale l'accueil", () => {
  const app = read("HermedBots/App/HermedBotsApp.swift");
  const occupying = "struct ErrorBanner {\n    var body: some View {\n        NoticeCard(tint: .orange, symbol: \"x\") { Text(\"err\") }\n    }\n}\n";
  const collapsed = "struct ErrorBanner {\n    var body: some View {\n        NoticeCard(tint: .orange, symbol: \"x\") { Text(\"err\") }\n            .frame(maxHeight: 0, alignment: .top)\n    }\n}\n";
  assert.equal(producedHomeShift(occupying, app), 1);
  assert.equal(producedHomeShift(collapsed, app), 0);
});
