"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const RUN_UI = join(ROOT, "docs", "spike", "hd14-instruments", "run-ui.sh");

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

function netCheck() {
  return firstBlock(readFileSync(RUN_UI, "utf8"), "hd14_net_check()");
}

function runNetCheckAt(file) {
  return spawnSync("bash", ["-c", `${netCheck()}\nhd14_net_check "$1"`, "bash", file], {
    encoding: "utf8",
  });
}

function runNetCheck(contents) {
  const dir = mkdtempSync(join(tmpdir(), "hd14-net-"));
  try {
    const file = join(dir, "net.txt");
    writeFileSync(file, contents);
    return runNetCheckAt(file);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("test01HeldBeforeLaunch pose la taille de fenêtre de test", () => {
  const ui = read("HermedBotsUITests/ConcurrencyTests.swift");
  const launch = firstBlock(ui, "override func launch");
  assert.match(launch, /app\.launchEnvironment\["HV_WINDOW_SIZE"\] = "1024x680"/);
  assert.match(launch, /waitForExistence\(timeout: 10\)/);
  assert.doesNotMatch(launch, /hasKeyboardFocus/);
  const held = firstBlock(ui, "func test01HeldBeforeLaunch");
  assert.match(held, /let app = launch\(\)/);

  const app = read("HermedBots/App/HermedBotsApp.swift");
  assert.match(app, /if let size = model\.testWindowSize \{ TestWindowSize\(size: size\) \}/);
  assert.match(app, /window\.setContentSize\(size\)/);

  const env = read("HermedBots/App/AppEnvironment.swift");
  assert.match(env, /testWindowSize: environment\["HV_WINDOW_SIZE"\]\.flatMap\(windowSize\)/);
});

test("le contrôle réseau hd14 accepte un relevé vide et refuse une destination interdite", () => {
  const script = readFileSync(RUN_UI, "utf8");
  assert.match(script, /hd14_net_check "\$HV_EVIDENCE\/net\.txt" \|\| rc=1/);
  assert.doesNotMatch(script, /NET sans preuve/);
  assert.doesNotMatch(
    script,
    /if \[ -s "\$HV_EVIDENCE\/net\.txt" \] && ! echo "\$destinations"/,
  );

  const empty = runNetCheck("");
  assert.equal(empty.status, 0, empty.stderr);
  assert.match(empty.stdout, /NET OK/);

  const missingDir = mkdtempSync(join(tmpdir(), "hd14-net-missing-"));
  try {
    const missing = runNetCheckAt(join(missingDir, "net.txt"));
    assert.equal(missing.status, 1, missing.stderr);
    assert.match(missing.stdout, /absent ou illisible/);
    const unread = join(missingDir, "unread.txt");
    writeFileSync(unread, "");
    chmodSync(unread, 0);
    const blocked = runNetCheckAt(unread);
    chmodSync(unread, 0o644);
    if (blocked.status !== 0) {
      assert.equal(blocked.status, 1, blocked.stderr);
      assert.match(blocked.stdout, /absent ou illisible/);
    }
  } finally {
    rmSync(missingDir, { recursive: true, force: true });
  }

  const allowed = runNetCheck("HermedBots 123 127.0.0.1:54321->127.0.0.1:18642 ESTABLISHED\n");
  assert.equal(allowed.status, 0, allowed.stderr);
  assert.match(allowed.stdout, /127\.0\.0\.1:18642/);

  const forbidden = runNetCheck("HermedBots 123 127.0.0.1:54321->203.0.113.9:443 ESTABLISHED\n");
  assert.equal(forbidden.status, 1, forbidden.stderr);
  assert.match(forbidden.stdout, /destination interdite/);

  const mixed = runNetCheck(
    "HermedBots 123 127.0.0.1:54321->127.0.0.1:18642 ESTABLISHED\nHermedBots 123 127.0.0.1:54322->203.0.113.9:443 ESTABLISHED\n",
  );
  assert.equal(mixed.status, 1, mixed.stderr);
  assert.match(mixed.stdout, /destination interdite/);
});
