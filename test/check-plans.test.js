"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..");
const script = join(root, "scripts/check-plans.js");
const plansDir = join(root, "docs/plans");

function run(args) {
  return spawnSync(process.execPath, [script, ...args], {
    cwd: root,
    encoding: "utf8",
  });
}

function listedPlans(stdout) {
  return stdout
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.endsWith(".md"))
    .map((line) => line.split("/").pop());
}

test("live docs/plans glob skips README", () => {
  const names = readdirSync(plansDir).filter((name) => name.endsWith(".md"));
  assert.ok(names.includes("README.md"));
  const result = run([]);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(
    listedPlans(result.stdout).sort(),
    names.filter((name) => name !== "README.md").sort(),
  );
  assert.doesNotMatch(result.stderr, /README\.md/);
});

test("a temp tree with a broken extra markdown file fails", () => {
  const dir = mkdtempSync(join(tmpdir(), "check-plans-"));
  const nested = join(dir, "nested");
  mkdirSync(nested);
  writeFileSync(join(dir, "README.md"), "# Plans\n");
  writeFileSync(join(dir, "notes.txt"), "not a plan\n");
  writeFileSync(join(dir, "broken.md"), "# broken\n");
  writeFileSync(join(nested, "also-broken.md"), "# nested\n");
  try {
    const result = run([dir]);
    assert.equal(result.status, 1);
    assert.deepEqual(listedPlans(result.stdout), ["broken.md"]);
    assert.match(result.stderr, /broken\.md:\d+:/);
    assert.doesNotMatch(result.stderr, /README\.md/);
    assert.doesNotMatch(result.stderr, /notes\.txt/);
    assert.doesNotMatch(result.stdout, /also-broken\.md/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
