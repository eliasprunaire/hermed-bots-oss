"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { existsSync, mkdtempSync, readFileSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..");
const bench = join(root, "scripts/shotdiff-bench.js");
const frozen = join(root, "test/fixtures/shotdiff/hv-shotdiff-main.sh");

function gitEnvWithoutOriginMain() {
  const dir = mkdtempSync(join(tmpdir(), "shotdiff-noref-"));
  const init = spawnSync("git", ["init", "-q", dir], { encoding: "utf8" });
  assert.equal(init.status, 0, init.stderr);
  return {
    dir,
    env: {
      ...process.env,
      GIT_DIR: join(dir, ".git"),
      GIT_WORK_TREE: dir,
    },
  };
}

test("le banc ne lit pas origin/main", () => {
  const src = readFileSync(bench, "utf8");
  assert.doesNotMatch(src, /origin\/main/);
  assert.ok(existsSync(frozen));
});

test("extractMainScript réussit sans origin/main", () => {
  const isolated = gitEnvWithoutOriginMain();
  try {
    const shown = spawnSync(
      "git",
      ["show", "origin/main:.cursor/skills/verify-hermed-bots/scripts/hv-shotdiff.sh"],
      { cwd: root, encoding: "utf8", env: isolated.env },
    );
    assert.notEqual(shown.status, 0, "le clone simulé ne doit pas exposer origin/main");
    const run = spawnSync(
      process.execPath,
      [
        "-e",
        `const { extractMainScript } = require(${JSON.stringify(bench)});
process.stdout.write(extractMainScript(${JSON.stringify(isolated.dir)}));`,
      ],
      { cwd: root, encoding: "utf8", env: isolated.env },
    );
    assert.equal(run.status, 0, run.stderr + run.stdout);
    assert.ok(existsSync(run.stdout));
    assert.ok(readFileSync(run.stdout).equals(readFileSync(frozen)));
  } finally {
    rmSync(isolated.dir, { recursive: true, force: true });
  }
});

test("le banc shotdiff affiche avant/après en 3 répétitions", () => {
  const isolated = gitEnvWithoutOriginMain();
  try {
    const run = spawnSync(process.execPath, [bench], {
      cwd: root,
      encoding: "utf8",
      timeout: 180000,
      env: isolated.env,
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
  } finally {
    rmSync(isolated.dir, { recursive: true, force: true });
  }
});
