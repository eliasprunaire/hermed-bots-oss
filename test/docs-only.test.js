"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { dirname, join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..");
const script = join(root, "scripts/docs-only.sh");

function git(cwd, ...args) {
  const result = spawnSync("git", ["-c", "core.hooksPath=/dev/null", ...args], {
    cwd,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function classifyAddedFile(relPath) {
  const dir = mkdtempSync(join(tmpdir(), "docs-only-js-"));
  try {
    git(dir, "init", "-q", "-b", "main");
    git(dir, "config", "user.email", "t@example.test");
    git(dir, "config", "user.name", "t");
    git(dir, "config", "commit.gpgsign", "false");
    writeFileSync(join(dir, "README.md"), "a\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "init");
    const base = git(dir, "rev-parse", "HEAD");
    mkdirSync(dirname(join(dir, relPath)), { recursive: true });
    writeFileSync(join(dir, relPath), "# agents\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "case");
    const result = spawnSync("bash", [script, base, "HEAD"], {
      cwd: dir,
      encoding: "utf8",
    });
    return { status: result.status, stdout: (result.stdout || "").trim() };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("docs-only.sh cases on a temporary git repo", () => {
  const result = spawnSync("bash", [join(root, "test/docs-only.sh")], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(result.stdout.trim(), "ok");
});

test("docs-only.sh rejects AGENTS.md letter-case variants", () => {
  for (const file of ["docs/agents.md", "docs/runbook/Agents.md", "Agents.MD"]) {
    const got = classifyAddedFile(file);
    assert.equal(got.status, 1, `${file} status ${got.status} out=${got.stdout}`);
    assert.equal(got.stdout.startsWith("DOCS-ONLY: no reason="), true, got.stdout);
  }
});
