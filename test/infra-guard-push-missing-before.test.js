"use strict";

const assert = require("node:assert/strict");
const { execFileSync, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const script = path.join(__dirname, "..", "scripts", "infra-guard-ci.js");
const j = (...p) => p.join("");
const secretLine = j("cd /Us", "ers/", "fixture/src");
const missing = "e".repeat(40);

function git(cwd, args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_SYSTEM: "/dev/null",
      GIT_OPTIONAL_LOCKS: "0",
    },
  }).trim();
}

function write(cwd, name, text) {
  fs.writeFileSync(path.join(cwd, name), text);
}

function commit(cwd, message) {
  git(cwd, ["add", "-A"]);
  git(cwd, ["-c", "user.name=dev", "-c", "user.email=dev@example.com", "commit", "-m", message]);
  return git(cwd, ["rev-parse", "HEAD"]);
}

function initRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ig-push-"));
  git(dir, ["init", "-b", "main"]);
  git(dir, ["config", "user.name", "dev"]);
  git(dir, ["config", "user.email", "dev@example.com"]);
  write(dir, "keep.txt", "ok\n");
  const mainSha = commit(dir, "base");
  git(dir, ["update-ref", "refs/remotes/origin/main", mainSha]);
  git(dir, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]);
  git(dir, ["checkout", "-b", "topic"]);
  return dir;
}

function flaggedRepo() {
  const dir = initRepo();
  write(dir, "flagged.txt", `${secretLine}\n`);
  const withSecret = commit(dir, "add flagged path");
  write(dir, "note.txt", "later\n");
  const after = commit(dir, "clean follow-up");
  return { dir, withSecret, after };
}

function cleanRepo() {
  const dir = initRepo();
  write(dir, "note.txt", "later\n");
  const after = commit(dir, "clean follow-up");
  return { dir, after };
}

function runPush(cwd, event) {
  const eventPath = path.join(cwd, "event.json");
  fs.writeFileSync(eventPath, JSON.stringify(event));
  return spawnSync(process.execPath, [script], {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GITHUB_EVENT_NAME: "push",
      GITHUB_EVENT_PATH: eventPath,
    },
  });
}

test("a missing push before SHA scans the merge-base range and flags a hidden added path", () => {
  const { dir, after } = flaggedRepo();
  const result = runPush(dir, {
    before: missing,
    after,
    commits: [{ id: after, message: "clean follow-up" }],
    repository: { default_branch: "main" },
  });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /flagged\.txt:\d+: HOME_PATH/);
  assert.ok(!result.stdout.includes("fixture/src"));
});

test("a missing push before SHA still reports clean when the widened range is clean", () => {
  const { dir, after } = cleanRepo();
  const result = runPush(dir, {
    before: missing,
    after,
    commits: [{ id: after, message: "clean follow-up" }],
    repository: { default_branch: "main" },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /infra-guard: clean/);
});

test("a null push before SHA uses the same widened scan, not a single-commit dump", () => {
  const { dir, after } = flaggedRepo();
  const result = runPush(dir, {
    before: "0".repeat(40),
    after,
    commits: [{ id: after, message: "clean follow-up" }],
    repository: { default_branch: "main" },
  });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /HOME_PATH/);
});

test("a reachable push before SHA keeps the narrow range", () => {
  const { dir, withSecret, after } = flaggedRepo();
  const result = runPush(dir, {
    before: withSecret,
    after,
    commits: [{ id: after, message: "clean follow-up" }],
    repository: { default_branch: "main" },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /infra-guard: clean/);
});

test("a missing head SHA stays a visible error, not a clean pass", () => {
  const { dir, after } = flaggedRepo();
  const result = runPush(dir, {
    before: "0".repeat(40),
    after: "a".repeat(40),
    commits: [{ id: after, message: "x" }],
    repository: { default_branch: "main" },
  });
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /infra-guard: clean/);
  assert.match(`${result.stderr}\n${result.stdout}`, /fatal|Not a valid object|unknown revision|bad revision|merge-base/i);
});
