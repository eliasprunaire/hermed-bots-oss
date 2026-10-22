"use strict";

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const PROTECTED_DIRS = [".claude/", ".codex/"];
const PROTECTED_FILES = [".mcp.json"];

// case-insensitive: macOS and Windows checkouts resolve .Claude/ to .claude/
function isProtected(file) {
  const lower = file.toLowerCase();
  return (
    PROTECTED_FILES.includes(lower) ||
    PROTECTED_DIRS.some((dir) => lower.startsWith(dir))
  );
}

function protectedPaths(files) {
  return files.filter(isProtected);
}

function hasProtectedPart(file) {
  return file
    .toLowerCase()
    .split(/[\\/]+/)
    .some((part) => part === ".mcp.json" || part === ".claude" || part === ".codex");
}

// a symlink is blocked when its own path or its target names a protected entry, or
// when its target resolves to the repo root or outside it (an ancestor of those entries)
function isProtectedSymlink(file, target) {
  if (hasProtectedPart(file) || hasProtectedPart(target)) {
    return true;
  }
  if (target.startsWith("/") || /^[a-z]:/i.test(target)) {
    return true;
  }
  const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(file), target));
  return resolved === "." || resolved === ".." || resolved.startsWith("../");
}

function parseArgs(argv) {
  if (argv.length === 4 && argv[0] === "--base" && argv[2] === "--head") {
    return { base: argv[1], head: argv[3] };
  }
  return null;
}

function git(args) {
  const result = spawnSync("git", args, { encoding: "buffer", maxBuffer: 64 * 1024 * 1024 });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(result.stderr.toString("utf8").trim() || "git failed");
  }
  return result.stdout;
}

// --no-renames lists both sides of a move, so a file moved out of .claude/ still counts
// raw records: ":<old mode> <new mode> <old sha> <new sha> <status>" NUL path NUL
function changedEntries(base, head) {
  const fields = git(["diff", "--raw", "--no-renames", "--no-abbrev", "-z", `${base}...${head}`])
    .toString("utf8")
    .split("\0")
    .filter(Boolean);
  const entries = [];
  for (let i = 0; i + 1 < fields.length; i += 2) {
    const [oldMode, mode, , sha] = fields[i].slice(1).split(" ");
    entries.push({ file: fields[i + 1], oldMode, mode, sha });
  }
  return entries;
}

function protectedSymlinks(entries) {
  return entries
    .filter((entry) => entry.mode === "120000")
    .filter((entry) => isProtectedSymlink(entry.file, git(["cat-file", "blob", entry.sha]).toString("utf8")))
    .map((entry) => entry.file);
}

// a gitlink (mode 160000) is a submodule: checkout fills its path with files outside this diff
function protectedSubmodules(entries) {
  return entries
    .filter((entry) => entry.oldMode === "160000" || entry.mode === "160000")
    .filter((entry) => hasProtectedPart(entry.file))
    .map((entry) => entry.file);
}

function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (args === null) {
    process.stderr.write("usage: node scripts/check-protected-paths.js --base SHA --head SHA\n");
    return 1;
  }
  let hits;
  try {
    const entries = changedEntries(args.base, args.head);
    hits = [
      ...protectedPaths(entries.map((entry) => entry.file)),
      ...protectedSymlinks(entries).map((file) => `${file} (symlink)`),
      ...protectedSubmodules(entries).map((file) => `${file} (submodule)`),
    ];
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    return 1;
  }
  if (hits.length === 0) {
    process.stdout.write("ok\n");
    return 0;
  }
  process.stderr.write(
    `protected agent config changed (.claude/, .codex/, .mcp.json, or a symlink or submodule at them):\n${hits.map((hit) => `  ${hit}`).join("\n")}\n`,
  );
  return 1;
}

if (require.main === module) {
  process.exitCode = main();
}

module.exports = { protectedPaths, isProtectedSymlink };
