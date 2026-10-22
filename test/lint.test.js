"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..");

function runLint(args) {
  const npmArgs = ["run", "lint"];
  if (args.length > 0) {
    npmArgs.push("--", ...args);
  }
  return spawnSync("npm", npmArgs, {
    cwd: root,
    encoding: "utf8",
  });
}

test("npm run lint exits 0", () => {
  const result = runLint([]);
  assert.equal(result.status, 0, result.stderr);
});

test("lint exits non-zero when a path has a syntax error", () => {
  const dir = mkdtempSync(join(tmpdir(), "lint-bad-"));
  const file = join(dir, "bad.js");
  writeFileSync(file, "function (\n");
  try {
    const result = runLint([file]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /SyntaxError/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
