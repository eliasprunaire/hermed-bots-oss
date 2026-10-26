"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { dirname, join } = require("node:path");
const { test } = require("node:test");

const { isProtectedSymlink, protectedPaths } = require("../scripts/check-protected-paths.js");

const root = join(__dirname, "..");
const script = join(root, "scripts/check-protected-paths.js");

test("matches .claude/, .codex/ and .mcp.json only", () => {
  const hits = protectedPaths([
    ".claude/settings.json",
    ".claude/skills/x/SKILL.md",
    ".codex/config.toml",
    ".mcp.json",
    ".Claude/settings.json",
    "server.js",
    "docs/.claude/notes.md",
    ".claudex/a",
    ".claude",
    ".mcp.json.bak",
    "sub/.mcp.json",
    "scripts/check-protected-paths.js",
  ]);
  assert.deepEqual(hits, [
    ".claude/settings.json",
    ".claude/skills/x/SKILL.md",
    ".codex/config.toml",
    ".mcp.json",
    ".Claude/settings.json",
  ]);
});

function git(cwd, ...args) {
  // no user or global hooks: they would block commits on main in the temp repo
  const result = spawnSync("git", ["-c", "core.hooksPath=/dev/null", ...args], {
    cwd,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

// text is file content, or { symlink: target } for a symbolic link
function put(dir, file, text) {
  mkdirSync(dirname(join(dir, file)), { recursive: true });
  if (typeof text === "object" && text !== null) {
    symlinkSync(text.symlink, join(dir, file));
  } else {
    writeFileSync(join(dir, file), text);
  }
}

// base on main, head on a branch off main; main moves on after the fork
function scenario(headFiles, mainFiles = {}) {
  const dir = mkdtempSync(join(tmpdir(), "check-protected-paths-"));
  try {
    git(dir, "init", "-q", "-b", "main");
    git(dir, "config", "user.email", "t@example.test");
    git(dir, "config", "user.name", "t");
    git(dir, "config", "commit.gpgsign", "false");
    put(dir, "README.md", "x\n");
    put(dir, ".claude/old.md", "old\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "init");
    git(dir, "switch", "-q", "-c", "topic");
    for (const [file, text] of Object.entries(headFiles)) {
      if (text === null) {
        rmSync(join(dir, file), { force: true });
      } else {
        put(dir, file, text);
      }
    }
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "topic");
    const head = git(dir, "rev-parse", "HEAD");
    git(dir, "switch", "-q", "main");
    for (const [file, text] of Object.entries(mainFiles)) {
      put(dir, file, text);
    }
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "--allow-empty", "-m", "main moves");
    const base = git(dir, "rev-parse", "HEAD");
    const result = spawnSync(process.execPath, [script, "--base", base, "--head", head], {
      cwd: dir,
      encoding: "utf8",
    });
    return result;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("a diff with no protected path exits 0", () => {
  const result = scenario({ "server.js": "ok\n" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, "");
});

test("an added, edited or deleted protected file exits 1 and names it", () => {
  for (const change of [
    { ".mcp.json": "{}\n" },
    { ".codex/config.toml": "a = 1\n" },
    { ".claude/old.md": "new\n" },
    { ".claude/old.md": null },
  ]) {
    const result = scenario({ "server.js": "ok\n", ...change });
    assert.equal(result.status, 1, JSON.stringify(change));
    assert.match(result.stderr, new RegExp(Object.keys(change)[0].replace(/\./g, "\\.")));
  }
});

test("a protected file changed only on base is not blamed on the head", () => {
  const result = scenario({ "server.js": "ok\n" }, { ".mcp.json": "{}\n" });
  assert.equal(result.status, 0, result.stderr);
});

test("a rename out of a protected directory exits 1", () => {
  const dir = mkdtempSync(join(tmpdir(), "check-protected-paths-"));
  try {
    git(dir, "init", "-q", "-b", "main");
    git(dir, "config", "user.email", "t@example.test");
    git(dir, "config", "user.name", "t");
    put(dir, ".claude/a.md", "same content\nline two\nline three\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "init");
    const base = git(dir, "rev-parse", "HEAD");
    git(dir, "mv", ".claude/a.md", "docs-a.md");
    git(dir, "commit", "-q", "-m", "move");
    const result = spawnSync(
      process.execPath,
      [script, "--base", base, "--head", "HEAD"],
      { cwd: dir, encoding: "utf8" },
    );
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\.claude\/a\.md/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a bad ref or missing arguments exit 1 (fail closed)", () => {
  const bad = spawnSync(process.execPath, [script, "--base", "nope", "--head", "nope"], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(bad.status, 1);
  assert.notEqual(bad.stderr, "");
  const usage = spawnSync(process.execPath, [script], { cwd: root, encoding: "utf8" });
  assert.equal(usage.status, 1);
  assert.match(usage.stderr, /usage:/);
});

test("isProtectedSymlink flags protected targets, names and escapes", () => {
  for (const [file, target] of [
    ["link", ".claude"],
    ["link", ".claude/settings.json"],
    ["link", "./.codex/"],
    ["link", ".mcp.json"],
    ["link", ".Claude/x"],
    ["docs/link", "../.claude/settings.json"],
    ["docs/link", "../.mcp.json"],
    ["link", "a/../.codex/config.toml"],
    ["link", "/abs/.claude"],
    ["link", "/etc/passwd"],
    ["link", "C:/x"],
    ["link", "."],
    ["link", ".."],
    ["docs/link", ".."],
    ["docs/link", "../../outside"],
    [".mcp.json", "server.js"],
    ["docs/.claude", "x"],
    ["sub/.codex", "x"],
  ]) {
    assert.equal(isProtectedSymlink(file, target), true, `${file} -> ${target}`);
  }
  for (const [file, target] of [
    ["link", "server.js"],
    ["docs/link", "../README.md"],
    ["docs/link", "other.md"],
    ["a/b/link", "../../x/y"],
    ["link", ".claudex/a"],
    ["link", "x.mcp.json"],
  ]) {
    assert.equal(isProtectedSymlink(file, target), false, `${file} -> ${target}`);
  }
});

test("an added or modified symlink to a protected entry exits 1 and names it", () => {
  for (const change of [
    { "link-claude": { symlink: ".claude" } },
    { "link-codex": { symlink: ".codex/config.toml" } },
    { "docs/mcp": { symlink: "../.mcp.json" } },
    { "docs/.claude": { symlink: "../README.md" } },
    { "up": { symlink: ".." } },
  ]) {
    const result = scenario({ "server.js": "ok\n", ...change });
    const name = Object.keys(change)[0];
    assert.equal(result.status, 1, name);
    assert.match(result.stderr, new RegExp(`${name.replace(/\./g, "\\.")} \\(symlink\\)`));
  }
});

test("a symlink modified to point at a protected entry exits 1", () => {
  const dir = mkdtempSync(join(tmpdir(), "check-protected-paths-"));
  try {
    git(dir, "init", "-q", "-b", "main");
    git(dir, "config", "user.email", "t@example.test");
    git(dir, "config", "user.name", "t");
    put(dir, "README.md", "x\n");
    put(dir, "link", { symlink: "README.md" });
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "init");
    const base = git(dir, "rev-parse", "HEAD");
    rmSync(join(dir, "link"));
    put(dir, "link", { symlink: ".claude/settings.json" });
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "retarget");
    const result = spawnSync(process.execPath, [script, "--base", base, "--head", "HEAD"], {
      cwd: dir,
      encoding: "utf8",
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /link \(symlink\)/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

const GITLINK_A = "1111111111111111111111111111111111111111";
const GITLINK_B = "2222222222222222222222222222222222222222";

// a gitlink entry (mode 160000) is what a submodule leaves in the tree
function gitlinkScenario(path, { before, after }) {
  const dir = mkdtempSync(join(tmpdir(), "check-protected-paths-"));
  const setGitlink = (sha) =>
    git(dir, "update-index", "--add", "--cacheinfo", `160000,${sha},${path}`);
  try {
    git(dir, "init", "-q", "-b", "main");
    git(dir, "config", "user.email", "t@example.test");
    git(dir, "config", "user.name", "t");
    put(dir, "README.md", "x\n");
    git(dir, "add", "-A");
    if (before) {
      setGitlink(before);
    }
    git(dir, "commit", "-q", "-m", "init");
    const base = git(dir, "rev-parse", "HEAD");
    if (after) {
      setGitlink(after);
    } else {
      git(dir, "rm", "-q", "--cached", path);
    }
    git(dir, "commit", "-q", "-m", "change");
    return spawnSync(process.execPath, [script, "--base", base, "--head", "HEAD"], {
      cwd: dir,
      encoding: "utf8",
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("an added, modified or removed submodule at a protected path exits 1 and names it", () => {
  for (const path of [".claude", ".codex", "docs/.claude"]) {
    for (const [label, change] of [
      ["add", { after: GITLINK_A }],
      ["modify", { before: GITLINK_A, after: GITLINK_B }],
      ["remove", { before: GITLINK_A }],
    ]) {
      const result = gitlinkScenario(path, change);
      assert.equal(result.status, 1, `${label} ${path}`);
      assert.match(result.stderr, new RegExp(`${path.replace(/\./g, "\\.")} \\(submodule\\)`));
    }
  }
});

test("a submodule at an unprotected path exits 0", () => {
  const result = gitlinkScenario("vendor/lib", { after: GITLINK_A });
  assert.equal(result.status, 0, result.stderr);
});

test("a harmless symlink exits 0", () => {
  const result = scenario({ "docs/link": { symlink: "../README.md" } });
  assert.equal(result.status, 0, result.stderr);
});

test("the workflow runs the checker from the base commit, not the PR branch", () => {
  const workflow = readFileSync(join(root, ".github/workflows/protected-paths.yml"), "utf8");
  assert.match(workflow, /git show "\$BASE_SHA:scripts\/check-protected-paths\.js"/);
  assert.doesNotMatch(workflow, /node scripts\/check-protected-paths\.js/);
});

test("the workflow fetches the head as git objects before the checker, without checking it out", () => {
  const workflow = readFileSync(join(root, ".github/workflows/protected-paths.yml"), "utf8");
  const fetchAt = workflow.indexOf('git fetch --no-tags origin "$HEAD_SHA"');
  const checkerAt = workflow.indexOf('node "$checker"');
  assert.ok(fetchAt !== -1, "the head SHA of a fork is not in the base clone: fetch it");
  assert.ok(fetchAt < checkerAt, "fetch before the checker reads the head");
  assert.doesNotMatch(workflow, /^\s+ref:/m);
  assert.match(workflow, /^\s+pull_request:$/m);
  assert.match(workflow, /^\s+pull_request_target:$/m);
});
