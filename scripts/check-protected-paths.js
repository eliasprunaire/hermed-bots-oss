"use strict";

const { spawnSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const {
  LineCounter,
  isAlias,
  isMap,
  isPair,
  isScalar,
  isSeq,
  parseAllDocuments,
  visit,
} = require("yaml");

const PROTECTED_DIRS = [".claude/", ".codex/"];
const PROTECTED_FILES = [".mcp.json"];
const GATE_FILES = [
  ".github/workflows/verdict-gate.yml",
  ".github/workflows/protected-paths.yml",
  ".github/workflows/anti-parallel.yml",
  "scripts/verdict-gate.js",
  "scripts/check-protected-paths.js",
  "scripts/check-anti-parallel.js",
  "scripts/verdict-prose.js",
];
const GATE_LABEL = "gate-change-approved";
const GATE_VERIFIER_LOGIN = "app-pilote-verifier[bot]";
const VERDICT_CONTEXT = "verdict-gate";
const HEX_SHA = /^[0-9a-fA-F]{40}$/;
const PULL_COMMIT_CAP = 250;
const RENOVATE_LOGINS = Object.freeze(["renovate[bot]", "mend-renovate[bot]"]);
const RENOVATE_EXEMPTION_MESSAGE =
  "exemption Renovate : uniquement des montées de version dans les workflows protégés";
const WORKFLOW_BUMP_REFUSED_MESSAGE =
  "exemption refusée : seuls jobs.<id>.steps[i].uses, jobs.<id>.container, jobs.<id>.container.image et jobs.<id>.services.<n>.image peuvent changer, au même chemin, même action ou même image, avec une référence toujours épinglée au moins aussi strictement";
const ACTION_TAG = /^v?\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z.]+)?$/;
const IMAGE_DIGEST = /^(.*)@(sha256:[0-9a-fA-F]{64})$/;
const IMAGE_TAG = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/;

function imageNameAndTag(rest) {
  const lastColon = rest.lastIndexOf(":");
  const lastSlash = rest.lastIndexOf("/");
  if (lastColon <= lastSlash) {
    return { name: rest, tag: null };
  }
  const name = rest.slice(0, lastColon);
  const tag = rest.slice(lastColon + 1);
  if (!name || !IMAGE_TAG.test(tag)) {
    return null;
  }
  return { name, tag };
}

// Docker: HOST:PORT/REPOSITORY is not NAME:TAG when a slash follows the colon.
function parseImageRef(ref) {
  const text = String(ref ?? "");
  if (text === "" || text.includes(" ")) {
    return null;
  }
  const digest = IMAGE_DIGEST.exec(text);
  if (digest) {
    const rest = digest[1];
    if (!rest || rest.includes("@")) {
      return null;
    }
    const parsed = imageNameAndTag(rest);
    if (parsed == null) {
      return null;
    }
    return { name: parsed.name, pin: "digest", ref: digest[2] };
  }
  const parsed = imageNameAndTag(text);
  if (parsed == null || parsed.tag == null) {
    return null;
  }
  return { name: parsed.name, pin: "tag", ref: parsed.tag };
}

function parseUsesRef(ref) {
  const text = String(ref ?? "");
  if (text.startsWith("docker://")) {
    const image = parseImageRef(text.slice("docker://".length));
    if (image == null) {
      return null;
    }
    return { name: `docker://${image.name}`, pin: image.pin, ref: image.ref };
  }
  const at = text.lastIndexOf("@");
  if (at <= 0) {
    return null;
  }
  const name = text.slice(0, at);
  const pinRef = text.slice(at + 1);
  if (!name || name.includes("@") || /\s/.test(name) || pinRef === "") {
    return null;
  }
  if (name.startsWith(".") || name.startsWith("/")) {
    return null;
  }
  if (HEX_SHA.test(pinRef)) {
    return { name, pin: "sha", ref: pinRef.toLowerCase() };
  }
  if (ACTION_TAG.test(pinRef)) {
    return { name, pin: "tag", ref: pinRef };
  }
  return null;
}

function pinRank(pin) {
  if (pin === "sha" || pin === "digest") {
    return 2;
  }
  if (pin === "tag") {
    return 1;
  }
  return 0;
}

function isAllowedPinBump(before, after, kind) {
  const parse = kind === "uses" ? parseUsesRef : parseImageRef;
  const left = parse(before);
  const right = parse(after);
  if (left == null || right == null) {
    return false;
  }
  if (left.name !== right.name) {
    return false;
  }
  if (left.pin === "sha" && right.pin !== "sha") {
    return false;
  }
  if (left.pin === "digest" && right.pin !== "digest") {
    return false;
  }
  if (pinRank(right.pin) < pinRank(left.pin)) {
    return false;
  }
  return String(before) !== String(after);
}

function pinKindAt(path) {
  if (!Array.isArray(path) || path[0] !== "jobs" || path.length < 3) {
    return null;
  }
  if (
    path.length === 5 &&
    path[2] === "steps" &&
    typeof path[3] === "number" &&
    path[4] === "uses"
  ) {
    return "uses";
  }
  if (path.length === 3 && path[2] === "container") {
    return "image";
  }
  if (path.length === 4 && path[2] === "container" && path[3] === "image") {
    return "image";
  }
  if (
    path.length === 5 &&
    path[2] === "services" &&
    typeof path[3] === "string" &&
    path[4] === "image"
  ) {
    return "image";
  }
  return null;
}

function pairKeyString(pair) {
  if (!isPair(pair) || pair.key == null) {
    return null;
  }
  if (!isScalar(pair.key) || pair.key.value == null) {
    return null;
  }
  return String(pair.key.value);
}

function nodeLine(node, lineCounter) {
  if (!node || !Array.isArray(node.range) || typeof node.range[0] !== "number") {
    return 1;
  }
  const pos = lineCounter.linePos(node.range[0]);
  return pos.line > 0 ? pos.line : 1;
}

function aliasName(node) {
  const raw = typeof node.source === "string" ? node.source : "";
  return raw.replace(/:$/, "");
}

function firstAnchorOrAlias(doc, lineCounter) {
  let hit = null;
  visit(doc, {
    Alias(_key, node) {
      if (hit) {
        return visit.BREAK;
      }
      hit = {
        kind: "alias",
        name: aliasName(node),
        line: nodeLine(node, lineCounter),
      };
      return visit.BREAK;
    },
    Node(_key, node) {
      if (hit) {
        return visit.BREAK;
      }
      if (node && typeof node.anchor === "string" && node.anchor !== "") {
        hit = {
          kind: "ancre",
          name: node.anchor,
          line: nodeLine(node, lineCounter),
        };
        return visit.BREAK;
      }
    },
  });
  return hit;
}

function refuseAnchorOrAliasMessage(hit) {
  if (hit.kind === "ancre") {
    return `ancre YAML &${hit.name} refusée`;
  }
  return `alias YAML *${hit.name} refusé`;
}

function yamlErrorMessage(err) {
  const detail = err && err.message ? String(err.message).replace(/\s+/g, " ").trim() : "";
  if (detail === "") {
    return "YAML invalide";
  }
  return `YAML invalide : ${detail}`;
}

function inspectWorkflow(text) {
  if (typeof text !== "string") {
    return { ok: false, message: "YAML invalide" };
  }
  const lineCounter = new LineCounter();
  let docs;
  try {
    docs = parseAllDocuments(text, { prettyErrors: true, lineCounter, uniqueKeys: true });
  } catch (err) {
    return { ok: false, message: yamlErrorMessage(err) };
  }
  if (docs.length !== 1) {
    return { ok: false, message: "le workflow YAML doit contenir exactement un document" };
  }
  const doc = docs[0];
  const hit = firstAnchorOrAlias(doc, lineCounter);
  if (hit) {
    return { ok: false, message: refuseAnchorOrAliasMessage(hit) };
  }
  if (doc.errors && doc.errors.length > 0) {
    return { ok: false, message: yamlErrorMessage(doc.errors[0]) };
  }
  if (isAlias(doc.contents)) {
    return { ok: false, message: refuseAnchorOrAliasMessage({ kind: "alias", name: aliasName(doc.contents) }) };
  }
  if (doc.contents == null) {
    return { ok: false, message: "YAML invalide" };
  }
  return { ok: true, doc };
}

function compareWorkflowNodes(left, right, path, acc) {
  if (left == null && right == null) {
    return true;
  }
  if (left == null || right == null) {
    return false;
  }
  if (isAlias(left) || isAlias(right)) {
    return false;
  }
  const kind = pinKindAt(path);
  if (kind != null && isScalar(left) && isScalar(right)) {
    const before = left.value == null ? "" : String(left.value);
    const after = right.value == null ? "" : String(right.value);
    if (before === after) {
      return true;
    }
    if (!isAllowedPinBump(before, after, kind)) {
      return false;
    }
    acc.count += 1;
    return true;
  }
  if (isScalar(left) && isScalar(right)) {
    return Object.is(left.value, right.value);
  }
  if (isMap(left) && isMap(right)) {
    if (left.items.length !== right.items.length) {
      return false;
    }
    for (let i = 0; i < left.items.length; i++) {
      const leftKey = pairKeyString(left.items[i]);
      const rightKey = pairKeyString(right.items[i]);
      if (leftKey == null || leftKey !== rightKey) {
        return false;
      }
      if (!compareWorkflowNodes(left.items[i].value, right.items[i].value, [...path, leftKey], acc)) {
        return false;
      }
    }
    return true;
  }
  if (isSeq(left) && isSeq(right)) {
    if (left.items.length !== right.items.length) {
      return false;
    }
    for (let i = 0; i < left.items.length; i++) {
      if (!compareWorkflowNodes(left.items[i], right.items[i], [...path, i], acc)) {
        return false;
      }
    }
    return true;
  }
  return false;
}

function isVersionOnlyWorkflowChange(before, after) {
  if (typeof before !== "string" || typeof after !== "string") {
    return { ok: false, message: "YAML invalide" };
  }
  if (before === after) {
    return { ok: false, message: WORKFLOW_BUMP_REFUSED_MESSAGE };
  }
  const left = inspectWorkflow(before);
  if (!left.ok) {
    return { ok: false, message: left.message };
  }
  const right = inspectWorkflow(after);
  if (!right.ok) {
    return { ok: false, message: right.message };
  }
  const acc = { count: 0 };
  if (!compareWorkflowNodes(left.doc.contents, right.doc.contents, [], acc)) {
    return { ok: false, message: WORKFLOW_BUMP_REFUSED_MESSAGE };
  }
  if (acc.count === 0) {
    return { ok: false, message: WORKFLOW_BUMP_REFUSED_MESSAGE };
  }
  return { ok: true };
}

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

function isRenovateLogin(login) {
  return RENOVATE_LOGINS.includes(login);
}

function isProtectedWorkflowPath(file) {
  return /^\.github\/workflows\/[^/]+\.ya?ml$/.test(posix(file));
}

function renovateWorkflowBumpExemption({ authorLogin, commitLogins, hits, fileChanges } = {}) {
  if (!isRenovateLogin(authorLogin)) {
    return { ok: false, reason: "author" };
  }
  if (!Array.isArray(commitLogins) || commitLogins.length === 0) {
    return { ok: false, reason: "commits" };
  }
  if (commitLogins.length >= PULL_COMMIT_CAP) {
    return { ok: false, reason: "commits" };
  }
  if (!commitLogins.every((login) => isRenovateLogin(login))) {
    return { ok: false, reason: "commits" };
  }
  if (!Array.isArray(hits) || hits.length === 0) {
    return { ok: false, reason: "path" };
  }
  if (!hits.every((hit) => isProtectedWorkflowPath(hit))) {
    return { ok: false, reason: "path" };
  }
  if (!Array.isArray(fileChanges)) {
    return { ok: false, reason: "diff" };
  }
  const byFile = new Map();
  for (const change of fileChanges) {
    if (change == null || typeof change !== "object") {
      return { ok: false, reason: "diff" };
    }
    if (typeof change.file !== "string") {
      return { ok: false, reason: "diff" };
    }
    byFile.set(posix(change.file), change);
  }
  for (const hit of hits) {
    const change = byFile.get(posix(hit));
    if (change == null) {
      return { ok: false, reason: "diff", message: WORKFLOW_BUMP_REFUSED_MESSAGE };
    }
    const compared = isVersionOnlyWorkflowChange(change.before, change.after);
    if (!compared.ok) {
      return { ok: false, reason: "diff", message: compared.message };
    }
  }
  return { ok: true };
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
  if (argv.length === 1 && argv[0] === "--refresh") {
    return { mode: "refresh" };
  }
  if (argv.length === 4 && argv[0] === "--base" && argv[2] === "--head") {
    return { mode: "check", base: argv[1], head: argv[3] };
  }
  return null;
}

function shouldRefreshFromEvent(eventName, payload) {
  if (payload == null || typeof payload !== "object") {
    return false;
  }
  if (eventName === "status") {
    return payload.context === VERDICT_CONTEXT && typeof payload.sha === "string" && HEX_SHA.test(payload.sha);
  }
  if (eventName === "pull_request_target") {
    if (payload.action !== "labeled" && payload.action !== "unlabeled") {
      return false;
    }
    return labelName(payload.label) === GATE_LABEL;
  }
  return false;
}

function runPullMatches(run, number, headSha) {
  if (run == null || typeof run !== "object") {
    return false;
  }
  if (run.event !== "pull_request_target") {
    return false;
  }
  if (run.status !== "completed") {
    return false;
  }
  if (!Array.isArray(run.pull_requests)) {
    return false;
  }
  const want = String(number);
  const sha = String(headSha).toLowerCase();
  for (const pull of run.pull_requests) {
    if (pull == null || typeof pull !== "object") {
      continue;
    }
    if (String(pull.number) !== want) {
      continue;
    }
    const head = pull.head && typeof pull.head.sha === "string" ? pull.head.sha.toLowerCase() : "";
    if (head === sha) {
      return true;
    }
  }
  return false;
}

function selectRunsToRerun(runs, { number, headSha } = {}) {
  if (!Array.isArray(runs) || number == null || typeof headSha !== "string" || !HEX_SHA.test(headSha)) {
    return [];
  }
  return runs.filter((run) => runPullMatches(run, number, headSha));
}

function refreshTargetsFromPull(payload) {
  const pull = payload && payload.pull_request;
  if (pull == null || typeof pull !== "object") {
    return [];
  }
  const sha = pull.head && typeof pull.head.sha === "string" ? pull.head.sha : "";
  if (!HEX_SHA.test(sha) || pull.number == null) {
    return [];
  }
  return [{ number: pull.number, headSha: sha.toLowerCase() }];
}

function refreshTargetsFromPulls(pulls, sha) {
  if (!Array.isArray(pulls) || typeof sha !== "string" || !HEX_SHA.test(sha)) {
    return [];
  }
  const want = sha.toLowerCase();
  const targets = [];
  for (const pull of pulls) {
    if (pull == null || typeof pull !== "object") {
      continue;
    }
    if (pull.state !== "open") {
      continue;
    }
    const head = pull.head && typeof pull.head.sha === "string" ? pull.head.sha.toLowerCase() : "";
    if (head !== want || pull.number == null) {
      continue;
    }
    targets.push({ number: pull.number, headSha: want });
  }
  return targets;
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

function isoTimeMs(raw, key) {
  if (raw == null || typeof raw !== "object") {
    return null;
  }
  if (typeof raw[key] !== "string" || raw[key] === "") {
    return null;
  }
  const ms = Date.parse(raw[key]);
  return Number.isFinite(ms) ? ms : null;
}

function verdictGateStatus(payload) {
  if (payload == null || typeof payload !== "object" || !Array.isArray(payload.statuses)) {
    return null;
  }
  for (const status of payload.statuses) {
    if (status == null || typeof status !== "object") {
      continue;
    }
    if (status.context === VERDICT_CONTEXT) {
      return status;
    }
  }
  return null;
}

// latest labeled/unlabeled event for GATE_LABEL wins; presence of the label on the
// pull payload is ignored. verdict-gate must be success on this head; the label
// created_at must be strictly after that status updated_at (never a commit date).
function gateApprovalFromEvents(events, { verdict } = {}) {
  if (!Array.isArray(events)) {
    return { ok: false, reason: "unreadable-events" };
  }
  let actor = null;
  let labeledAt = null;
  for (const event of events) {
    if (event == null || typeof event !== "object") {
      continue;
    }
    if (labelName(event.label) !== GATE_LABEL) {
      continue;
    }
    if (event.event === "labeled") {
      actor = event.actor;
      labeledAt = isoTimeMs(event, "created_at");
    } else if (event.event === "unlabeled") {
      actor = null;
      labeledAt = null;
    }
  }
  if (actor == null) {
    return { ok: false, reason: "no-label" };
  }
  const actorLogin = foldLogin(readLogin(actor));
  if (actorLogin !== GATE_VERIFIER_LOGIN) {
    return { ok: false, reason: "not-verifier" };
  }
  if (verdict == null || verdict.state !== "success") {
    return { ok: false, reason: "no-verdict-gate" };
  }
  const greenAt = isoTimeMs(verdict, "updated_at") ?? isoTimeMs(verdict, "created_at");
  if (labeledAt == null || greenAt == null || labeledAt <= greenAt) {
    return { ok: false, reason: "stale-label" };
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

async function loadCommitStatus(io, token, owner, repo, sha) {
  const response = await githubGet(
    io,
    token,
    `https://api.github.com/repos/${owner}/${repo}/commits/${sha}/status`,
  );
  return response.json();
}

async function githubPost(io, token, url) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = await io.fetch(url, {
        method: "POST",
        headers: {
          ...apiHeaders(token),
          "Content-Type": "application/json",
        },
        body: "{}",
      });
      if (response && (response.ok || response.status === 201)) {
        return response;
      }
    } catch {
      continue;
    }
  }
  throw new Error("POST failed");
}

async function loadWorkflowRuns(io, token, owner, repo) {
  const items = [];
  let url = `https://api.github.com/repos/${owner}/${repo}/actions/workflows/protected-paths.yml/runs?event=pull_request_target&per_page=100`;
  while (url) {
    const response = await githubGet(io, token, url);
    const page = await response.json();
    if (page == null || typeof page !== "object" || !Array.isArray(page.workflow_runs)) {
      throw new Error("page is unreadable");
    }
    items.push(...page.workflow_runs);
    url = nextUrl(response.headers.get("link"));
  }
  return items;
}

async function loadCommitPulls(io, token, owner, repo, sha) {
  const response = await githubGet(
    io,
    token,
    `https://api.github.com/repos/${owner}/${repo}/commits/${sha}/pulls`,
  );
  return response.json();
}

async function refreshTargets(io, token, owner, repo, eventName, payload) {
  if (eventName === "pull_request_target") {
    return refreshTargetsFromPull(payload);
  }
  if (eventName === "status") {
    let pulls;
    try {
      pulls = await loadCommitPulls(io, token, owner, repo, payload.sha);
    } catch {
      return null;
    }
    return refreshTargetsFromPulls(pulls, payload.sha);
  }
  return [];
}

async function refreshRuns(io) {
  const token = io.env.GITHUB_TOKEN;
  const repository = io.env.GITHUB_REPOSITORY;
  const eventName = io.env.GITHUB_EVENT_NAME;
  const eventPath = io.env.GITHUB_EVENT_PATH;
  const names = repositoryParts(repository);
  if (!token || names == null || !eventName || !eventPath) {
    return 1;
  }
  let payload;
  try {
    payload = JSON.parse(io.readFile(eventPath));
  } catch {
    return 1;
  }
  if (!shouldRefreshFromEvent(eventName, payload)) {
    process.stdout.write("ok\n");
    return 0;
  }
  const targets = await refreshTargets(io, token, names.owner, names.repo, eventName, payload);
  if (targets == null) {
    return 1;
  }
  if (targets.length === 0) {
    process.stdout.write("ok\n");
    return 0;
  }
  let runs;
  try {
    runs = await loadWorkflowRuns(io, token, names.owner, names.repo);
  } catch {
    return 1;
  }
  const selected = [];
  const seen = new Set();
  for (const target of targets) {
    for (const run of selectRunsToRerun(runs, target)) {
      if (typeof run.id !== "number" && typeof run.id !== "string") {
        continue;
      }
      const key = String(run.id);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      selected.push(run);
    }
  }
  for (const run of selected) {
    try {
      await githubPost(
        io,
        token,
        `https://api.github.com/repos/${names.owner}/${names.repo}/actions/runs/${run.id}/rerun`,
      );
    } catch {
      return 1;
    }
  }
  process.stdout.write("ok\n");
  return 0;
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
      ? `protected gate files changed (${GATE_FILES.join(", ")}). ${GATE_VERIFIER_LOGIN} label ${GATE_LABEL} after verdict-gate success on head required`
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
  let payload;
  try {
    payload = await loadCommitStatus(io, token, names.owner, names.repo, headSha);
  } catch {
    return { ok: false, reason: "unreadable-status" };
  }
  return gateApprovalFromEvents(events, { verdict: verdictGateStatus(payload) });
}

function blobText(commit, file) {
  const spec = `${commit}:${file}`;
  const probe = spawnSync("git", ["cat-file", "-e", spec], {
    encoding: "buffer",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (probe.status !== 0) {
    return null;
  }
  return git(["cat-file", "blob", spec]).toString("utf8");
}

function fileChangesFor(base, head, files) {
  const ancestor = git(["merge-base", base, head]).toString("utf8").trim();
  return files.map((file) => ({
    file,
    before: blobText(ancestor, file),
    after: blobText(head, file),
  }));
}

function commitLogin(raw) {
  if (raw == null || typeof raw !== "object") {
    return null;
  }
  return readLogin(raw.author);
}

async function loadPullCommitLogins(io) {
  const token = io.env.GITHUB_TOKEN;
  const repository = io.env.GITHUB_REPOSITORY;
  const number = io.env.PR_NUMBER;
  const names = repositoryParts(repository);
  if (!token || names == null || !number) {
    return null;
  }
  let items;
  try {
    items = await loadPages(
      io,
      token,
      `https://api.github.com/repos/${names.owner}/${names.repo}/pulls/${number}/commits?per_page=100`,
    );
  } catch {
    return null;
  }
  if (items.length >= PULL_COMMIT_CAP) {
    return null;
  }
  const logins = [];
  for (const raw of items) {
    const login = commitLogin(raw);
    if (login == null) {
      logins.push(null);
      continue;
    }
    logins.push(login);
  }
  return logins;
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
    process.stderr.write(
      "usage: node scripts/check-protected-paths.js --base SHA --head SHA\n" +
        "       node scripts/check-protected-paths.js --refresh\n",
    );
    return 1;
  }
  if (args.mode === "refresh") {
    return refreshRuns(io);
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
  const hits = [...agent, ...gate];
  if (hits.length > 0 && isRenovateLogin(io.env.PR_AUTHOR_LOGIN)) {
    const commitLogins = await loadPullCommitLogins(io);
    const workflowHits = hits.filter((hit) => isProtectedWorkflowPath(hit));
    let fileChanges = [];
    if (workflowHits.length > 0) {
      try {
        fileChanges = fileChangesFor(args.base, args.head, workflowHits);
      } catch {
        fileChanges = [];
      }
    }
    const exemption = renovateWorkflowBumpExemption({
      authorLogin: io.env.PR_AUTHOR_LOGIN,
      commitLogins,
      hits,
      fileChanges,
    });
    if (exemption.ok) {
      process.stdout.write(`${RENOVATE_EXEMPTION_MESSAGE}\n`);
      return 0;
    }
    if (typeof exemption.message === "string" && exemption.message !== "") {
      process.stderr.write(`${exemption.message}\n`);
    }
  }
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
  readFile(path) {
    return readFileSync(path, "utf8");
  },
};

module.exports = {
  protectedPaths,
  isProtectedSymlink,
  isGateFile,
  classifyHits,
  gateApprovalFromEvents,
  isVersionOnlyWorkflowChange,
  renovateWorkflowBumpExemption,
  shouldRefreshFromEvent,
  selectRunsToRerun,
  WORKFLOW_BUMP_REFUSED_MESSAGE,
  GATE_FILES,
  GATE_LABEL,
  RENOVATE_EXEMPTION_MESSAGE,
  RENOVATE_LOGINS,
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
