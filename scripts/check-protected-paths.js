"use strict";

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const PROTECTED_DIRS = [".claude/", ".codex/"];
const PROTECTED_FILES = [".mcp.json"];
const GATE_FILES = [
  ".github/workflows/verdict-gate.yml",
  ".github/workflows/protected-paths.yml",
  ".github/workflows/anti-parallel.yml",
  "scripts/verdict-gate.js",
  "scripts/check-protected-paths.js",
  "scripts/check-anti-parallel.js",
];
const GATE_LABEL = "gate-change-approved";
const GATE_VERIFIER_LOGIN = "app-pilote-verifier[bot]";
const VERDICT_MARKER = "<!-- dev-lead-verifier -->";
const VERDICT_LINE = /^VERDICT: (PASS\+NOTES|PASS|FAIL) @ ([0-9a-fA-F]{40})$/;
const HEX_SHA = /^[0-9a-fA-F]{40}$/;

function posix(file) {
  return String(file).replace(/\\/g, "/").toLowerCase();
}

function isAgentPath(file) {
  const lower = posix(file);
  return (
    PROTECTED_FILES.includes(lower) ||
    PROTECTED_DIRS.some((dir) => lower.startsWith(dir))
  );
}

function isGateFile(file) {
  const lower = posix(file);
  return GATE_FILES.some((name) => lower === name);
}

// case-insensitive: macOS and Windows checkouts resolve .Claude/ to .claude/
function isProtected(file) {
  return isAgentPath(file) || isGateFile(file);
}

function protectedPaths(files) {
  return files.filter(isProtected);
}

function hasProtectedPart(file) {
  return posix(file)
    .split(/[\\/]+/)
    .some((part) => part === ".mcp.json" || part === ".claude" || part === ".codex");
}

function gateTarget(file, target) {
  if (isGateFile(file)) {
    return true;
  }
  const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(file), target));
  return isGateFile(resolved);
}

// a symlink is blocked when its own path or its target names a protected entry, or
// when its target resolves to the repo root or outside it (an ancestor of those entries)
function isProtectedSymlink(file, target) {
  if (hasProtectedPart(file) || hasProtectedPart(target) || gateTarget(file, target)) {
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
    .filter((entry) => hasProtectedPart(entry.file) || isGateFile(entry.file))
    .map((entry) => entry.file);
}

function classifyHits(files) {
  const agent = [];
  const gate = [];
  for (const file of files) {
    const name = String(file).replace(/ \(symlink\)$/, "").replace(/ \(submodule\)$/, "");
    if (isAgentPath(name) || hasProtectedPart(name)) {
      agent.push(file);
    } else if (isGateFile(name)) {
      gate.push(file);
    }
  }
  return { agent, gate };
}

function foldLogin(value) {
  if (typeof value !== "string" || value === "") {
    return null;
  }
  return value.toLowerCase();
}

function readLogin(user) {
  if (user == null || typeof user !== "object") {
    return null;
  }
  if (typeof user.login !== "string" || user.login === "") {
    return null;
  }
  return user.login;
}

function labelName(raw) {
  if (raw == null || typeof raw !== "object") {
    return null;
  }
  if (typeof raw.name !== "string") {
    return null;
  }
  return raw.name;
}

function resolveHeadSha(head) {
  const sha = git(["rev-parse", "--verify", `${head}^{commit}`]).toString("utf8").trim();
  if (!HEX_SHA.test(sha)) {
    throw new Error("head is not a commit");
  }
  return sha.toLowerCase();
}

function commentUser(comment) {
  if (comment == null || typeof comment !== "object") {
    return null;
  }
  return comment.user;
}

function commentBody(comment) {
  if (comment == null || typeof comment !== "object") {
    return null;
  }
  if (typeof comment.body !== "string") {
    return null;
  }
  return comment.body;
}

// last marked VERDICT from the verifier that cites headSha wins; FAIL cancels a prior PASS
function hasVerifierPassForHead(comments, headSha) {
  if (!Array.isArray(comments) || typeof headSha !== "string" || !HEX_SHA.test(headSha)) {
    return false;
  }
  const want = headSha.toLowerCase();
  let pass = false;
  for (const comment of comments) {
    if (foldLogin(readLogin(commentUser(comment))) !== GATE_VERIFIER_LOGIN) {
      continue;
    }
    const body = commentBody(comment);
    if (body == null || !body.includes(VERDICT_MARKER)) {
      continue;
    }
    for (const line of body.split(/\r?\n/)) {
      const match = VERDICT_LINE.exec(line);
      if (!match || match[2].toLowerCase() !== want) {
        continue;
      }
      pass = match[1] === "PASS" || match[1] === "PASS+NOTES";
    }
  }
  return pass;
}

// latest labeled/unlabeled event for GATE_LABEL wins; presence of the label on the
// pull payload is ignored. the label is bound to the head SHA via a marked PASS or
// PASS+NOTES from the same verifier; commit dates are not used.
function gateApprovalFromEvents(events, { headSha, comments } = {}) {
  if (!Array.isArray(events)) {
    return { ok: false, reason: "unreadable-events" };
  }
  let actor = null;
  for (const event of events) {
    if (event == null || typeof event !== "object") {
      continue;
    }
    if (labelName(event.label) !== GATE_LABEL) {
      continue;
    }
    if (event.event === "labeled") {
      actor = event.actor;
    } else if (event.event === "unlabeled") {
      actor = null;
    }
  }
  if (actor == null) {
    return { ok: false, reason: "no-label" };
  }
  const actorLogin = foldLogin(readLogin(actor));
  if (actorLogin !== GATE_VERIFIER_LOGIN) {
    return { ok: false, reason: "not-verifier" };
  }
  if (!hasVerifierPassForHead(comments, headSha)) {
    return { ok: false, reason: "no-pass-for-head" };
  }
  return { ok: true, login: actorLogin };
}

function nextUrl(link) {
  if (typeof link !== "string" || link === "") {
    return null;
  }
  for (const part of link.split(",")) {
    const match = /<([^>]+)>;\s*rel="next"/.exec(part);
    if (match) {
      return match[1];
    }
  }
  return null;
}

function apiHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2026-03-10",
    "User-Agent": "protected-paths",
  };
}

async function githubGet(io, token, url) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = await io.fetch(url, { headers: apiHeaders(token) });
      if (response && response.ok) {
        return response;
      }
    } catch {
      continue;
    }
  }
  throw new Error("GET failed");
}

async function loadPages(io, token, startUrl) {
  const items = [];
  let url = startUrl;
  while (url) {
    const response = await githubGet(io, token, url);
    const page = await response.json();
    if (!Array.isArray(page)) {
      throw new Error("page is unreadable");
    }
    items.push(...page);
    url = nextUrl(response.headers.get("link"));
  }
  return items;
}

async function loadEvents(io, token, owner, repo, number) {
  return loadPages(
    io,
    token,
    `https://api.github.com/repos/${owner}/${repo}/issues/${number}/timeline?per_page=100`,
  );
}

async function loadComments(io, token, owner, repo, number) {
  return loadPages(
    io,
    token,
    `https://api.github.com/repos/${owner}/${repo}/issues/${number}/comments?per_page=100`,
  );
}

function repositoryParts(repository) {
  if (typeof repository !== "string") {
    return null;
  }
  const parts = repository.split("/");
  if (parts.length !== 2 || parts[0] === "" || parts[1] === "") {
    return null;
  }
  return { owner: parts[0], repo: parts[1] };
}

function writeHits(kind, hits) {
  const label =
    kind === "gate"
      ? `protected gate files changed (${GATE_FILES.join(", ")}). ${GATE_VERIFIER_LOGIN} label ${GATE_LABEL} and PASS @ head required`
      : "protected agent config changed (.claude/, .codex/, .mcp.json, or a symlink or submodule at them)";
  process.stderr.write(
    `${label}:\n${hits.map((hit) => `  ${hit}`).join("\n")}\n`,
  );
}

async function ownerApproval(io, headSha) {
  const token = io.env.GITHUB_TOKEN;
  const repository = io.env.GITHUB_REPOSITORY;
  const number = io.env.PR_NUMBER;
  const names = repositoryParts(repository);
  if (!token || names == null || !number) {
    return { ok: false, reason: "missing-context" };
  }
  let events;
  try {
    events = await loadEvents(io, token, names.owner, names.repo, number);
  } catch {
    return { ok: false, reason: "unreadable-events" };
  }
  let comments;
  try {
    comments = await loadComments(io, token, names.owner, names.repo, number);
  } catch {
    return { ok: false, reason: "unreadable-comments" };
  }
  return gateApprovalFromEvents(events, { headSha, comments });
}

function collectHits(base, head) {
  const entries = changedEntries(base, head);
  const agent = [];
  const gate = [];
  for (const file of protectedPaths(entries.map((entry) => entry.file))) {
    if (isGateFile(file)) {
      gate.push(file);
    } else {
      agent.push(file);
    }
  }
  for (const file of protectedSymlinks(entries)) {
    const hit = `${file} (symlink)`;
    if (isGateFile(file)) {
      gate.push(hit);
    } else {
      agent.push(hit);
    }
  }
  for (const file of protectedSubmodules(entries)) {
    const hit = `${file} (submodule)`;
    if (isGateFile(file)) {
      gate.push(hit);
    } else {
      agent.push(hit);
    }
  }
  return { agent, gate };
}

async function main(argv = process.argv.slice(2), io = defaultIo) {
  const args = parseArgs(argv);
  if (args === null) {
    process.stderr.write("usage: node scripts/check-protected-paths.js --base SHA --head SHA\n");
    return 1;
  }
  let grouped;
  let headSha;
  try {
    grouped = collectHits(args.base, args.head);
    headSha = resolveHeadSha(args.head);
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    return 1;
  }
  const { agent, gate } = grouped;
  if (agent.length > 0) {
    writeHits("agent", agent);
    return 1;
  }
  if (gate.length === 0) {
    process.stdout.write("ok\n");
    return 0;
  }
  const approval = await ownerApproval(io, headSha);
  if (approval.ok) {
    process.stdout.write("ok\n");
    return 0;
  }
  writeHits("gate", gate);
  return 1;
}

const defaultIo = {
  env: process.env,
  fetch(url, init) {
    return globalThis.fetch(url, init);
  },
};

module.exports = {
  protectedPaths,
  isProtectedSymlink,
  isGateFile,
  classifyHits,
  gateApprovalFromEvents,
  GATE_FILES,
  GATE_LABEL,
  main,
};

if (require.main === module) {
  main()
    .then((code) => {
      process.exitCode = code;
    })
    .catch((err) => {
      process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
      process.exitCode = 1;
    });
}
