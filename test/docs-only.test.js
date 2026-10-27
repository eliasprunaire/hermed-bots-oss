"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..");

test("docs-only.sh cases on a temporary git repo", () => {
  const result = spawnSync("bash", [join(root, "test/docs-only.sh")], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(result.stdout.trim(), "ok");
});
