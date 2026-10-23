"use strict";

const { spawnSync } = require("node:child_process");
const { chmodSync, copyFileSync, mkdirSync, writeFileSync } = require("node:fs");
const path = require("node:path");

const HOOK_SCRIPT = [
  "#!/bin/sh",
  'root=$(CDPATH= cd -- "$(dirname "$0")" && pwd) || exit 1',
  'exec node "$root/check-commit-msg.js" "$1"',
  "",
].join("\n");

const PRE_PUSH_SCRIPT = [
  "#!/bin/sh",
  'root=$(CDPATH= cd -- "$(dirname "$0")" && pwd) || exit 1',
  'exec node "$root/check-pre-push.js"',
  "",
].join("\n");

const POST_CHECKOUT = [
  "#!/bin/sh",
  'root=$(CDPATH= cd -- "$(dirname "$0")" && pwd) || exit 0',
  'top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0',
  'configured=$(git config --get core.hooksPath 2>/dev/null || true)',
  'case "$configured" in',
  '  /*) resolved=$configured ;;',
  '  "") resolved="" ;;',
  '  *) resolved=$top/$configured ;;',
  "esac",
  'if [ -n "$resolved" ] && [ -x "$resolved/commit-msg" ]; then',
  "  exit 0",
  "fi",
  'rel=$root',
  'case "$root" in',
  '  "$top"/*) rel=${root#"$top"/} ;;',
  "esac",
  'git config --worktree core.hooksPath "$rel" || exit 0',
  "exit 0",
  "",
].join("\n");

function worktreeHooksPath(worktree, hooksDir) {
  const rel = path.relative(path.resolve(worktree), hooksDir);
  if (rel === "") return ".";
  return rel.split(path.sep).join("/");
}

function git(cwd, args) {
  return spawnSync("git", args, { cwd, encoding: "utf8" });
}

function installDispatcher(cwd) {
  const common = git(cwd, ["rev-parse", "--git-common-dir"]);
  if (common.status !== 0) {
    const detail = (common.stderr || common.stdout || "git rev-parse --git-common-dir failed").trim();
    console.error(detail);
    return { error: common.status || 1 };
  }
  const dest = path.resolve(cwd, common.stdout.trim(), "hermed-bots-hooks");
  mkdirSync(dest, { recursive: true });
  copyFileSync(path.join(__dirname, "check-commit-msg.js"), path.join(dest, "check-commit-msg.js"));
  copyFileSync(
    path.join(__dirname, "check-pr-attribution.js"),
    path.join(dest, "check-pr-attribution.js"),
  );
  const hook = path.join(dest, "commit-msg");
  writeFileSync(hook, HOOK_SCRIPT);
  chmodSync(hook, 0o755);
  const postCheckout = path.join(dest, "post-checkout");
  writeFileSync(postCheckout, POST_CHECKOUT);
  chmodSync(postCheckout, 0o755);
  copyFileSync(
    path.join(__dirname, "check-pre-push.js"),
    path.join(dest, "check-pre-push.js"),
  );
  const prePush = path.join(dest, "pre-push");
  writeFileSync(prePush, PRE_PUSH_SCRIPT);
  chmodSync(prePush, 0o755);
  return { dest };
}

// Rule 13: the hooks written above replace pre-push; re-chain an optional extra
// local check (outside the repo) so its pre-commit/pre-push checks stay active.
function chainInfraGuard(cwd, env = process.env) {
  const bin = env.INFRA_GUARD_BIN || "infra-guard";
  const top = git(cwd, ["rev-parse", "--show-toplevel"]);
  const repo = top.status === 0 ? top.stdout.trim() : cwd;
  const res = spawnSync(bin, ["install", repo], { cwd, encoding: "utf8", env });
  if (res.error && res.error.code === "ENOENT") {
    console.warn("install-git-hooks: extra local check not found, local rule 13 hooks not chained (warning only)");
    return "missing";
  }
  if (res.error || res.status !== 0) {
    console.warn(`install-git-hooks: infra-guard install failed (${res.error ? res.error.code : res.status}), warning only`);
    return "failed";
  }
  return "ok";
}

function installGitHooks(cwd = process.cwd()) {
  const probe = git(cwd, ["rev-parse", "--is-inside-work-tree"]);
  if (probe.error || probe.status !== 0 || String(probe.stdout).trim() !== "true") {
    return 0;
  }
  const enable = git(cwd, ["config", "--local", "extensions.worktreeConfig", "true"]);
  if (enable.status !== 0) {
    const detail = (enable.stderr || enable.stdout || "git config extensions.worktreeConfig failed").trim();
    console.error(detail);
    return enable.status || 1;
  }
  git(cwd, ["config", "--local", "--unset-all", "core.hooksPath"]);
  const dispatcher = installDispatcher(cwd);
  if (dispatcher.error) {
    return dispatcher.error;
  }
  const set = git(cwd, [
    "config",
    "--worktree",
    "core.hooksPath",
    worktreeHooksPath(cwd, dispatcher.dest),
  ]);
  if (set.status !== 0) {
    const detail = (set.stderr || set.stdout || "git config core.hooksPath failed").trim();
    console.error(detail);
    return set.status || 1;
  }
  return 0;
}

// CLI entry (npm prepare / npm test): write the hooks, then re-chain infra-guard.
// installGitHooks alone stays side-effect free for the hook tests on temp repos.
function main(cwd = process.cwd(), env = process.env) {
  const rc = installGitHooks(cwd);
  if (rc !== 0) return rc;
  // Only checkouts that can push somewhere need the rule 13 guard (temp test repos have no remote).
  const remotes = git(cwd, ["remote"]);
  if (remotes.status === 0 && remotes.stdout.trim() !== "") chainInfraGuard(cwd, env);
  return 0;
}

module.exports = { installGitHooks, chainInfraGuard, main };

if (require.main === module) {
  process.exitCode = main();
}
