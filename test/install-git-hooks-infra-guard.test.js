"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const { main: installGitHooks } = require("../scripts/install-git-hooks.js");

function tempRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "igh-"));
  spawnSync("git", ["init", "-q", dir]);
  spawnSync("git", ["-C", dir, "remote", "add", "origin", "https://example.invalid/o/r.git"]);
  return dir;
}

test("install-git-hooks (CLI) re-runs `infra-guard install <repo>` after writing the hooks", () => {
  const repo = tempRepo();
  const bin = path.join(repo, "fake-infra-guard");
  const log = path.join(repo, "calls");
  fs.writeFileSync(bin, `#!/bin/sh\nls "$2/.git/hermed-bots-hooks/pre-push" >/dev/null && echo "$@" >> "${log}"\n`, { mode: 0o755 });
  const rc = installGitHooks(repo, { ...process.env, INFRA_GUARD_BIN: bin });
  assert.equal(rc, 0);
  const calls = fs.readFileSync(log, "utf8").trim().split("\n");
  assert.equal(calls.length, 1);
  assert.equal(calls[0], `install ${fs.realpathSync(repo)}`);
});

test("install-git-hooks (CLI) only warns when infra-guard is missing", () => {
  const repo = tempRepo();
  const warn = console.warn; const seen = [];
  console.warn = (m) => seen.push(m);
  try {
    const rc = installGitHooks(repo, { ...process.env, INFRA_GUARD_BIN: path.join(repo, "does-not-exist") });
    assert.equal(rc, 0);
  } finally { console.warn = warn; }
  assert.ok(seen.some((m) => /infra-guard not found/.test(m)));
  assert.ok(fs.existsSync(path.join(repo, ".git", "hermed-bots-hooks", "pre-push")));
});

test("installGitHooks alone never calls infra-guard (hook tests stay hermetic)", () => {
  const repo = tempRepo();
  const bin = path.join(repo, "spy");
  const log = path.join(repo, "calls");
  fs.writeFileSync(bin, `#!/bin/sh\necho "$@" >> "${log}"\n`, { mode: 0o755 });
  const prev = process.env.INFRA_GUARD_BIN; process.env.INFRA_GUARD_BIN = bin;
  try { assert.equal(require("../scripts/install-git-hooks.js").installGitHooks(repo), 0); } finally { if (prev === undefined) delete process.env.INFRA_GUARD_BIN; else process.env.INFRA_GUARD_BIN = prev; }
  assert.ok(!fs.existsSync(log));
});

test("install-git-hooks (CLI) only warns when infra-guard install fails", () => {
  const repo = tempRepo();
  const bin = path.join(repo, "failing");
  fs.writeFileSync(bin, "#!/bin/sh\nexit 4\n", { mode: 0o755 });
  const warn = console.warn; const seen = [];
  console.warn = (m) => seen.push(m);
  try { assert.equal(installGitHooks(repo, { ...process.env, INFRA_GUARD_BIN: bin }), 0); } finally { console.warn = warn; }
  assert.ok(seen.some((m) => /infra-guard install failed \(4\)/.test(m)));
});

test("install-git-hooks (CLI) does not chain infra-guard in a checkout without remote", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "igh-"));
  spawnSync("git", ["init", "-q", dir]);
  const bin = path.join(dir, "spy");
  const log = path.join(dir, "calls");
  fs.writeFileSync(bin, `#!/bin/sh\necho "$@" >> "${log}"\n`, { mode: 0o755 });
  assert.equal(installGitHooks(dir, { ...process.env, INFRA_GUARD_BIN: bin }), 0);
  assert.ok(!fs.existsSync(log));
});
