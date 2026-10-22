const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, statSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join, resolve } = require("node:path");
const { test } = require("node:test");
const { main } = require("../scripts/check-pre-push.js");

const repoRoot = join(__dirname, "..");
const installer = join(repoRoot, "scripts", "install-git-hooks.js");
const hooksDir = join(repoRoot, ".githooks");

function runMain(text) {
  const error = console.error;
  const chunks = [];
  console.error = (...args) => {
    chunks.push(args.map(String).join(" "));
  };
  try {
    return { code: main(text), err: chunks.join("\n") };
  } finally {
    console.error = error;
  }
}

function git(cwd, args) {
  return spawnSync("git", args, { cwd, encoding: "utf8" });
}

test("a push whose remote ref is refs/heads/main is refused", () => {
  const { code, err } = runMain(
    "refs/heads/feat/hook-probe aaa refs/heads/main bbb\n",
  );
  assert.equal(code, 1);
  assert.match(err, /refusing push to refs\/heads\/main/);
});

test("a push whose remote ref is refs/heads/Main is refused", () => {
  const { code, err } = runMain(
    "refs/heads/feat/hook-probe aaa refs/heads/Main bbb\n",
  );
  assert.equal(code, 1);
  assert.match(err, /refusing push to refs\/heads\/main/);
});

test("a push of a feature ref is allowed", () => {
  const feature = runMain(
    "refs/heads/feat/hook-probe aaa refs/heads/feat/hook-probe bbb\n",
  );
  assert.equal(feature.code, 0);
  assert.equal(feature.err, "");
  const near = runMain("refs/heads/main aaa refs/heads/main-extra bbb\n");
  assert.equal(near.code, 0);
  assert.equal(near.err, "");
});

test("a malformed pre-push line is refused", () => {
  const { code, err } = runMain("refs/heads/feat/hook-probe aaa refs/heads/feat/hook-probe\n");
  assert.equal(code, 1);
  assert.match(err, /malformed pre-push update/);
});

test("the versioned pre-push hook is executable and refuses main", () => {
  const hook = join(hooksDir, "pre-push");
  assert.equal(statSync(hook).mode & 0o111, 0o111);
  const staged = git(repoRoot, ["ls-files", "--stage", ".githooks/pre-push"]);
  assert.equal(staged.status, 0, staged.stderr);
  assert.match(staged.stdout, /^100755\s/);
  const run = spawnSync(hook, [], {
    input: "refs/heads/feat/hook-probe aaa refs/heads/main bbb\n",
    encoding: "utf8",
  });
  assert.equal(run.status, 1);
  assert.match(`${run.stderr}\n${run.stdout}`, /refusing push to refs\/heads\/main/);
});

test("the installer copies an executable pre-push next to commit-msg", () => {
  const dir = mkdtempSync(join(tmpdir(), "pre-push-install-"));
  assert.equal(git(dir, ["init"]).status, 0);
  const run = spawnSync(process.execPath, [installer], {
    cwd: dir,
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stderr);
  const common = git(dir, ["rev-parse", "--git-common-dir"]);
  assert.equal(common.status, 0, common.stderr);
  const dest = resolve(dir, common.stdout.trim(), "hermed-bots-hooks");
  const hook = join(dest, "pre-push");
  assert.equal(statSync(hook).mode & 0o111, 0o111);
  assert.equal(statSync(join(dest, "commit-msg")).mode & 0o111, 0o111);
  assert.equal(statSync(join(dest, "check-pre-push.js")).isFile(), true);
  const refused = spawnSync(hook, [], {
    input: "refs/heads/topic aaa refs/heads/main bbb\n",
    encoding: "utf8",
  });
  assert.equal(refused.status, 1);
  assert.match(`${refused.stderr}\n${refused.stdout}`, /main/);
  const allowed = spawnSync(hook, [], {
    input: "refs/heads/topic aaa refs/heads/feat/hook-probe bbb\n",
    encoding: "utf8",
  });
  assert.equal(allowed.status, 0, `${allowed.stderr}\n${allowed.stdout}`);
});

test("git push refuses main and accepts a feature ref", () => {
  const bare = mkdtempSync(join(tmpdir(), "pre-push-bare-"));
  const work = mkdtempSync(join(tmpdir(), "pre-push-work-"));
  assert.equal(git(bare, ["init", "--bare"]).status, 0);
  assert.equal(git(work, ["init", "-b", "main"]).status, 0);
  assert.equal(git(work, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(work, ["config", "user.name", "Dev"]).status, 0);
  assert.equal(git(work, ["remote", "add", "origin", bare]).status, 0);
  writeFileSync(join(work, "README"), "seed\n");
  assert.equal(git(work, ["add", "README"]).status, 0);
  assert.equal(
    git(work, ["-c", "commit.gpgsign=false", "commit", "-m", "seed"]).status,
    0,
  );
  const installed = spawnSync(process.execPath, [installer], {
    cwd: work,
    encoding: "utf8",
  });
  assert.equal(installed.status, 0, installed.stderr);

  const feature = git(work, ["push", "origin", "HEAD:refs/heads/feat/hook-probe"]);
  assert.equal(feature.status, 0, `${feature.stderr}\n${feature.stdout}`);
  assert.equal(git(bare, ["rev-parse", "--verify", "refs/heads/feat/hook-probe"]).status, 0);

  const denied = git(work, ["push", "origin", "main"]);
  assert.equal(denied.status, 1);
  assert.match(`${denied.stderr}\n${denied.stdout}`, /main/);
  assert.notEqual(git(bare, ["rev-parse", "--verify", "refs/heads/main"]).status, 0);
});
