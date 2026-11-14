"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const repoRoot = join(__dirname, "..");
const hooksDir = join(repoRoot, ".githooks");
const trailer = ["Co-authored-by:", "x <x@y>"].join(" ");
const frenchRefusal = /trailer Co-authored-by interdit/;

function git(cwd, args, extraEnv = {}) {
  return spawnSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_SYSTEM: "/dev/null",
      GIT_EDITOR: "true",
      ...extraEnv,
    },
  });
}

function seedRepo() {
  const dir = mkdtempSync(join(tmpdir(), "coauthored-trailer-"));
  assert.equal(git(dir, ["init", "-q", "-b", "main"]).status, 0);
  assert.equal(git(dir, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(dir, ["config", "user.name", "Dev"]).status, 0);
  assert.equal(git(dir, ["config", "commit.gpgsign", "false"]).status, 0);
  writeFileSync(join(dir, "file.txt"), "one\n");
  assert.equal(git(dir, ["add", "file.txt"]).status, 0);
  const seed = git(dir, ["-c", "core.hooksPath=/dev/null", "commit", "-m", "seed"]);
  assert.equal(seed.status, 0, seed.stderr);
  writeFileSync(join(dir, "file.txt"), "two\n");
  assert.equal(git(dir, ["add", "file.txt"]).status, 0);
  const change = git(dir, ["-c", "core.hooksPath=/dev/null", "commit", "-m", "change"]);
  assert.equal(change.status, 0, change.stderr);
  return dir;
}

function writeInjectorPrepare(dir) {
  const hooks = join(dir, "tmp-hooks");
  mkdirSync(hooks);
  writeFileSync(
    join(hooks, "prepare-commit-msg"),
    `#!/bin/sh\nprintf '\\n${trailer}\\n' >> "$1"\n`,
  );
  chmodSync(join(hooks, "prepare-commit-msg"), 0o755);
  return hooks;
}

function writeChainedPrepare(dir) {
  const hooks = join(dir, "tmp-hooks");
  mkdirSync(hooks);
  const real = join(hooksDir, "prepare-commit-msg");
  writeFileSync(
    join(hooks, "prepare-commit-msg"),
    `#!/bin/sh\nprintf '\\n${trailer}\\n' >> "$1"\nexec "${real}" "$@"\n`,
  );
  chmodSync(join(hooks, "prepare-commit-msg"), 0o755);
  return hooks;
}

test("without the hook, a trailer commit and a revert that adds the trailer both land", () => {
  const commitDir = seedRepo();
  const revertDir = seedRepo();
  try {
    const bad = git(commitDir, [
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "--allow-empty",
      "-m",
      "feat: should land",
      "-m",
      trailer,
    ]);
    assert.equal(bad.status, 0, `${bad.stderr}\n${bad.stdout}`);
    assert.match(git(commitDir, ["log", "-1", "--format=%B"]).stdout, /^Co-authored-by: x <x@y>$/m);

    const injectHooks = writeInjectorPrepare(revertDir);
    assert.equal(git(revertDir, ["config", "core.hooksPath", injectHooks]).status, 0);
    const reverted = git(revertDir, ["revert", "--no-edit", "HEAD"]);
    assert.equal(reverted.status, 0, `${reverted.stderr}\n${reverted.stdout}`);
    assert.match(
      git(revertDir, ["log", "-1", "--format=%B"]).stdout,
      /^Co-authored-by: x <x@y>$/m,
    );
  } finally {
    rmSync(commitDir, { recursive: true, force: true });
    rmSync(revertDir, { recursive: true, force: true });
  }
});

test("with the hook, a trailer commit is refused in French, a clean commit lands, and a revert that would add the trailer is refused or cleaned", () => {
  const commitDir = seedRepo();
  const revertDir = seedRepo();
  try {
    assert.equal(git(commitDir, ["config", "core.hooksPath", hooksDir]).status, 0);
    const bad = git(commitDir, [
      "commit",
      "--allow-empty",
      "-m",
      "feat: should not land",
      "-m",
      trailer,
    ]);
    assert.notEqual(bad.status, 0);
    assert.match(`${bad.stderr}\n${bad.stdout}`, frenchRefusal);

    const clean = git(commitDir, [
      "commit",
      "--allow-empty",
      "-m",
      "feat: note propre",
    ]);
    assert.equal(clean.status, 0, `${clean.stderr}\n${clean.stdout}`);
    assert.doesNotMatch(
      git(commitDir, ["log", "-1", "--format=%B"]).stdout,
      /^[ \t]*Co-authored-by:/m,
    );

    const chained = writeChainedPrepare(revertDir);
    assert.equal(git(revertDir, ["config", "core.hooksPath", chained]).status, 0);
    const head = git(revertDir, ["rev-parse", "HEAD"]).stdout.trim();
    const reverted = git(revertDir, ["revert", "--no-edit", "HEAD"]);
    const body = git(revertDir, ["log", "-1", "--format=%B"]).stdout;
    if (reverted.status === 0) {
      assert.doesNotMatch(body, /^[ \t]*Co-authored-by:/m);
      assert.notEqual(git(revertDir, ["rev-parse", "HEAD"]).stdout.trim(), head);
    } else {
      assert.match(`${reverted.stderr}\n${reverted.stdout}`, frenchRefusal);
      assert.equal(git(revertDir, ["rev-parse", "HEAD"]).stdout.trim(), head);
    }
  } finally {
    rmSync(commitDir, { recursive: true, force: true });
    rmSync(revertDir, { recursive: true, force: true });
  }
});

test("the cloud install step sets core.hooksPath to the versioned hooks", () => {
  const env = JSON.parse(
    readFileSync(join(repoRoot, ".cursor", "environment.json"), "utf8"),
  );
  assert.match(String(env.install), /core\.hooksPath/);
  assert.match(String(env.install), /\.githooks/);
});
