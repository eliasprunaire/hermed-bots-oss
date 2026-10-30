const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const {
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join, resolve } = require("node:path");
const { test } = require("node:test");
const { main } = require("../scripts/check-commit-msg.js");

const repoRoot = join(__dirname, "..");
const installer = join(repoRoot, "scripts", "install-git-hooks.js");
const hooksDir = join(repoRoot, ".githooks");

function runMain(argv) {
  const error = console.error;
  const chunks = [];
  console.error = (...args) => {
    chunks.push(args.map(String).join(" "));
  };
  try {
    return { code: main(argv), err: chunks.join("\n") };
  } finally {
    console.error = error;
  }
}

function messageFile(name, text) {
  const dir = mkdtempSync(join(tmpdir(), "commit-msg-"));
  const file = join(dir, name);
  writeFileSync(file, text);
  return file;
}

function git(cwd, args) {
  return spawnSync("git", args, { cwd, encoding: "utf8" });
}

test("a clean commit message is accepted", () => {
  const file = messageFile("clean", "feat: add the commit-msg hook\n");
  assert.equal(main([file]), 0);
});

test("a Co-authored-by trailer is rejected", () => {
  const file = messageFile(
    "trailer",
    "feat: add the commit-msg hook\n\nCo-authored-by: Bot <bot@example.com>\n",
  );
  const { code, err } = runMain([file]);
  assert.equal(code, 1);
  assert.match(err, /commit message contains Co-authored-by/);
});

test("a human Co-authored-by trailer is rejected with no allowlist", () => {
  const file = messageFile(
    "human-trailer",
    "feat: add the commit-msg hook\n\nCo-authored-by: Human Reviewer <human@example.com>\n",
  );
  const { code, err } = runMain([file]);
  assert.equal(code, 1);
  assert.match(err, /commit message contains Co-authored-by/);
});

test("an Open in Cursor footer is rejected", () => {
  const file = messageFile("footer", "See Open in Cursor for the session.\n");
  const { code, err } = runMain([file]);
  assert.equal(code, 1);
  assert.match(err, /commit message contains Open in Cursor/);
});

test("a cursor.com/agents URL is rejected", () => {
  const file = messageFile(
    "url",
    "Notes live at https://cursor.com/agents/abc\n",
  );
  const { code, err } = runMain([file]);
  assert.equal(code, 1);
  assert.match(err, /commit message contains cursor\.com\/agents/);
});

test("the versioned commit-msg hook is executable", () => {
  const hook = join(hooksDir, "commit-msg");
  const mode = statSync(hook).mode;
  assert.equal(mode & 0o111, 0o111);
  const staged = git(repoRoot, ["ls-files", "--stage", ".githooks/commit-msg"]);
  assert.equal(staged.status, 0, staged.stderr);
  assert.match(staged.stdout, /^100755\s/);
});

test("the installer sets core.hooksPath in a git checkout", () => {
  const dir = mkdtempSync(join(tmpdir(), "hooks-install-"));
  assert.equal(git(dir, ["init"]).status, 0);
  const first = spawnSync(process.execPath, [installer], {
    cwd: dir,
    encoding: "utf8",
  });
  assert.equal(first.status, 0, first.stderr);
  const second = spawnSync(process.execPath, [installer], {
    cwd: dir,
    encoding: "utf8",
  });
  assert.equal(second.status, 0, second.stderr);
  const got = git(dir, ["config", "--get", "core.hooksPath"]);
  const common = git(dir, ["rev-parse", "--git-common-dir"]);
  assert.equal(common.status, 0, common.stderr);
  const expected = resolve(dir, common.stdout.trim(), "hermed-bots-hooks");
  const configured = got.stdout.trim();
  assert.equal(resolve(dir, configured), expected);
  assert.equal(configured.startsWith("/"), false);
  assert.equal(statSync(join(expected, "commit-msg")).mode & 0o111, 0o111);
});

test("the installer does not set hooksPath on a sibling worktree", () => {
  const main = mkdtempSync(join(tmpdir(), "hooks-main-"));
  assert.equal(git(main, ["init"]).status, 0);
  assert.equal(git(main, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(main, ["config", "user.name", "Dev"]).status, 0);
  assert.equal(
    git(main, ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "init"]).status,
    0,
  );
  const sib = mkdtempSync(join(tmpdir(), "hooks-sib-"));
  rmSync(sib, { recursive: true, force: true });
  const added = git(main, ["worktree", "add", sib, "-b", "sib"]);
  assert.equal(added.status, 0, added.stderr);
  const run = spawnSync(process.execPath, [installer], {
    cwd: main,
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stderr);
  assert.notEqual(git(main, ["config", "--get", "core.hooksPath"]).stdout.trim(), "");
  assert.equal(git(sib, ["config", "--get", "core.hooksPath"]).stdout.trim(), "");
});

test("the installer exits 0 outside a git checkout", () => {
  const dir = mkdtempSync(join(tmpdir(), "hooks-nogit-"));
  const run = spawnSync(process.execPath, [installer], {
    cwd: dir,
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(run.stderr, "");
});

test("git commit rejects a trailer and accepts a clean message", () => {
  const dir = mkdtempSync(join(tmpdir(), "hooks-commit-"));
  assert.equal(git(dir, ["init"]).status, 0);
  assert.equal(git(dir, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(dir, ["config", "user.name", "Dev"]).status, 0);
  assert.equal(git(dir, ["config", "core.hooksPath", hooksDir]).status, 0);

  const clean = git(dir, [
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-m",
    "feat: add a clean note",
  ]);
  assert.equal(clean.status, 0, clean.stderr);
  const head = git(dir, ["rev-parse", "HEAD"]).stdout.trim();
  const body = git(dir, ["log", "-1", "--format=%B"]).stdout;
  assert.doesNotMatch(body, /^[ \t]*Co-authored-by:/m);

  const bad = git(dir, [
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-m",
    "feat: should not land",
    "-m",
    "Co-authored-by: Bot <bot@example.com>",
  ]);
  assert.notEqual(bad.status, 0);
  assert.match(`${bad.stderr}\n${bad.stdout}`, /Co-authored-by/);
  assert.equal(git(dir, ["rev-parse", "HEAD"]).stdout.trim(), head);
});

test("git commit -F rejects a comment-prefixed co-author trailer", () => {
  const dir = mkdtempSync(join(tmpdir(), "hooks-file-"));
  assert.equal(git(dir, ["init"]).status, 0);
  assert.equal(git(dir, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(dir, ["config", "user.name", "Dev"]).status, 0);
  assert.equal(git(dir, ["config", "core.hooksPath", hooksDir]).status, 0);

  const cleanFile = join(dir, "clean.txt");
  writeFileSync(cleanFile, "feat: add a clean note\n\n# A review note\n");
  const clean = git(dir, [
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-F",
    cleanFile,
  ]);
  assert.equal(clean.status, 0, `${clean.stderr}\n${clean.stdout}`);
  const head = git(dir, ["rev-parse", "HEAD"]).stdout.trim();
  const stored = git(dir, ["log", "-1", "--format=%B"]).stdout;
  assert.match(stored, /feat: add a clean note/);
  assert.match(stored, /# A review note/);

  const badFile = join(dir, "bad.txt");
  writeFileSync(
    badFile,
    "feat: should not land\n\n# Co-authored-by: Bot <bot@example.com>\n",
  );
  const bad = git(dir, [
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-F",
    badFile,
  ]);
  assert.notEqual(bad.status, 0);
  assert.match(`${bad.stderr}\n${bad.stdout}`, /commit message contains Co-authored-by/);
  assert.equal(git(dir, ["rev-parse", "HEAD"]).stdout.trim(), head);
});

test("git commit -F rejects a co-author trailer with a space before the colon", () => {
  const dir = mkdtempSync(join(tmpdir(), "hooks-space-"));
  assert.equal(git(dir, ["init"]).status, 0);
  assert.equal(git(dir, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(dir, ["config", "user.name", "Dev"]).status, 0);
  assert.equal(git(dir, ["config", "core.hooksPath", hooksDir]).status, 0);

  const cleanFile = join(dir, "clean.txt");
  writeFileSync(cleanFile, "feat: add a clean note\n");
  const clean = git(dir, [
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-F",
    cleanFile,
  ]);
  assert.equal(clean.status, 0, `${clean.stderr}\n${clean.stdout}`);
  const head = git(dir, ["rev-parse", "HEAD"]).stdout.trim();

  const badFile = join(dir, "bad.txt");
  writeFileSync(
    badFile,
    "feat: should not land\n\nCo-authored-by : Bot bot@example.com\n",
  );
  const bad = git(dir, [
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-F",
    badFile,
  ]);
  assert.notEqual(bad.status, 0);
  assert.match(
    `${bad.stderr}\n${bad.stdout}`,
    /commit message contains Co-authored-by/,
  );
  assert.equal(git(dir, ["rev-parse", "HEAD"]).stdout.trim(), head);
});

test("a moved checkout still rejects a co-author trailer", () => {
  const parent = mkdtempSync(join(tmpdir(), "hooks-move-"));
  const dir = join(parent, "repo");
  mkdirSync(dir);
  assert.equal(git(dir, ["init"]).status, 0);
  assert.equal(git(dir, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(dir, ["config", "user.name", "Dev"]).status, 0);
  const run = spawnSync(process.execPath, [installer], {
    cwd: dir,
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stderr);
  const moved = join(parent, "moved");
  renameSync(dir, moved);
  const bad = git(moved, [
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-m",
    "feat: should not land",
    "-m",
    "Co-authored-by: Bot <bot@example.com>",
  ]);
  assert.notEqual(bad.status, 0);
  assert.match(
    `${bad.stderr}\n${bad.stdout}`,
    /commit message contains Co-authored-by/,
  );
});

test("a worktree added after install rejects a co-author trailer", () => {
  const main = mkdtempSync(join(tmpdir(), "hooks-after-"));
  assert.equal(git(main, ["init"]).status, 0);
  assert.equal(git(main, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(main, ["config", "user.name", "Dev"]).status, 0);
  writeFileSync(join(main, "README"), "old\n");
  assert.equal(git(main, ["add", "README"]).status, 0);
  assert.equal(
    git(main, ["-c", "commit.gpgsign=false", "commit", "-m", "old tree"]).status,
    0,
  );
  const old = git(main, ["rev-parse", "HEAD"]).stdout.trim();
  const run = spawnSync(process.execPath, [installer], {
    cwd: main,
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stderr);
  const sib = mkdtempSync(join(tmpdir(), "hooks-after-sib-"));
  rmSync(sib, { recursive: true, force: true });
  const added = git(main, ["worktree", "add", "--detach", sib, old]);
  assert.equal(added.status, 0, added.stderr);
  assert.equal(existsSync(join(sib, ".githooks")), false);
  const mainPath = git(main, ["config", "--get", "core.hooksPath"]).stdout.trim();
  const sibPath = git(sib, ["config", "--get", "core.hooksPath"]).stdout.trim();
  assert.notEqual(mainPath, "");
  assert.notEqual(sibPath, "");
  assert.equal(
    realpathSync(resolve(main, mainPath)),
    realpathSync(resolve(sib, sibPath)),
  );

  const clean = git(sib, [
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-m",
    "feat: add a clean note",
  ]);
  assert.equal(clean.status, 0, `${clean.stderr}\n${clean.stdout}`);
  const head = git(sib, ["rev-parse", "HEAD"]).stdout.trim();
  const bad = git(sib, [
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-m",
    "feat: should not land",
    "-m",
    "Co-authored-by: Bot <bot@example.com>",
  ]);
  assert.notEqual(bad.status, 0);
  assert.match(
    `${bad.stderr}\n${bad.stdout}`,
    /commit message contains Co-authored-by/,
  );
  assert.equal(git(sib, ["rev-parse", "HEAD"]).stdout.trim(), head);
});

test("a later checkout does not retarget a worktree added with --no-checkout", () => {
  const main = mkdtempSync(join(tmpdir(), "hooks-nocheck-main-"));
  assert.equal(git(main, ["init"]).status, 0);
  assert.equal(git(main, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(main, ["config", "user.name", "Dev"]).status, 0);
  assert.equal(git(main, ["config", "commit.gpgsign", "false"]).status, 0);
  assert.equal(
    git(main, ["commit", "--allow-empty", "-m", "seed"]).status,
    0,
  );
  const run = spawnSync(process.execPath, [installer], {
    cwd: main,
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stderr);
  const old = git(main, ["rev-parse", "HEAD"]).stdout.trim();
  const sib = mkdtempSync(join(tmpdir(), "hooks-nocheck-sib-"));
  rmSync(sib, { recursive: true, force: true });
  const added = git(main, ["worktree", "add", "--no-checkout", sib, old]);
  assert.equal(added.status, 0, added.stderr);
  const copied = git(sib, ["config", "--get", "core.hooksPath"]).stdout.trim();
  const checkout = git(sib, ["checkout"]);
  assert.equal(checkout.status, 0, `${checkout.stderr}\n${checkout.stdout}`);
  assert.equal(
    git(sib, ["config", "--get", "core.hooksPath"]).stdout.trim(),
    copied,
  );
  const bad = git(sib, [
    "commit",
    "--allow-empty",
    "-m",
    "feat: should not land",
    "-m",
    "Co-authored-by: Bot <bot@example.com>",
  ]);
  assert.equal(bad.status, 0, `${bad.stderr}\n${bad.stdout}`);
});

test("renaming the primary checkout leaves the linked worktree hook stale after repair", () => {
  const parent = mkdtempSync(join(tmpdir(), "hooks-rename-"));
  const main = join(parent, "main");
  mkdirSync(main);
  assert.equal(git(main, ["init"]).status, 0);
  assert.equal(git(main, ["config", "user.email", "dev@example.com"]).status, 0);
  assert.equal(git(main, ["config", "user.name", "Dev"]).status, 0);
  assert.equal(git(main, ["config", "commit.gpgsign", "false"]).status, 0);
  assert.equal(
    git(main, ["commit", "--allow-empty", "-m", "seed"]).status,
    0,
  );
  const run = spawnSync(process.execPath, [installer], {
    cwd: main,
    encoding: "utf8",
  });
  assert.equal(run.status, 0, run.stderr);
  const old = git(main, ["rev-parse", "HEAD"]).stdout.trim();
  const sib = join(parent, "sib");
  const added = git(main, ["worktree", "add", "--detach", sib, old]);
  assert.equal(added.status, 0, added.stderr);
  const before = git(sib, [
    "commit",
    "--allow-empty",
    "-m",
    "feat: should not land",
    "-m",
    "Co-authored-by: Bot <bot@example.com>",
  ]);
  assert.notEqual(before.status, 0);
  const renamed = join(parent, "renamed");
  renameSync(main, renamed);
  const repair = git(renamed, ["worktree", "repair", sib]);
  assert.equal(repair.status, 0, repair.stderr);
  const after = git(sib, [
    "commit",
    "--allow-empty",
    "-m",
    "feat: should not land",
    "-m",
    "Co-authored-by: Bot <bot@example.com>",
  ]);
  assert.equal(after.status, 0, `${after.stderr}\n${after.stdout}`);
  const primary = git(renamed, [
    "commit",
    "--allow-empty",
    "-m",
    "feat: should not land",
    "-m",
    "Co-authored-by: Bot <bot@example.com>",
  ]);
  assert.notEqual(primary.status, 0);
  assert.match(
    `${primary.stderr}\n${primary.stdout}`,
    /commit message contains Co-authored-by/,
  );
});
