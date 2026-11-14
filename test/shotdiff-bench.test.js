"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..");
const bench = join(root, "scripts/shotdiff-bench.js");

test("le banc shotdiff affiche avant/après en 3 répétitions", () => {
  const run = spawnSync(process.execPath, [bench], {
    cwd: root,
    encoding: "utf8",
    timeout: 180000,
  });
  assert.equal(run.status, 0, run.stderr + run.stdout);
  assert.match(run.stdout, /3 répétitions/);
  assert.match(run.stdout, /1280x800/);
  assert.match(run.stdout, /avant \(main\)/);
  assert.match(run.stdout, /après \(tête\)/);
  const medians = [...run.stdout.matchAll(/médiane ([0-9.]+) s\/paire/g)].map((m) =>
    Number(m[1]),
  );
  assert.equal(medians.length, 4, run.stdout);
  for (const value of medians) {
    assert.ok(value > 0, String(value));
  }
  const speedups = [...run.stdout.matchAll(/accélération médiane ([0-9.]+)×/g)];
  assert.equal(speedups.length, 2, run.stdout);
});
