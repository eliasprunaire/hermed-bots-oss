"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { dirname, join } = require("node:path");
const { test } = require("node:test");

const {
  GATE_FILES,
  GATE_LABEL,
  classifyHits,
  gateApprovalFromEvents,
  isGateFile,
  isProtectedSymlink,
  main,
  protectedPaths,
} = require("../scripts/check-protected-paths.js");

const root = join(__dirname, "..");
const script = join(root, "scripts/check-protected-paths.js");

test("matches agent config and the gate files", () => {
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
    "scripts/verdict-gate.js",
    ".github/workflows/verdict-gate.yml",
    ".github/workflows/protected-paths.yml",
    ".github/workflows/anti-parallel.yml",
    "scripts/check-anti-parallel.js",
    "docs/scripts/verdict-gate.js",
  ]);
  assert.deepEqual(hits, [
    ".claude/settings.json",
    ".claude/skills/x/SKILL.md",
    ".codex/config.toml",
    ".mcp.json",
    ".Claude/settings.json",
    "scripts/check-protected-paths.js",
    "scripts/verdict-gate.js",
    ".github/workflows/verdict-gate.yml",
    ".github/workflows/protected-paths.yml",
    ".github/workflows/anti-parallel.yml",
    "scripts/check-anti-parallel.js",
  ]);
  for (const file of GATE_FILES) {
    assert.equal(isGateFile(file), true, file);
  }
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
    ["link", "scripts/verdict-gate.js"],
    ["link", ".github/workflows/protected-paths.yml"],
    ["scripts/verdict-gate.js", "server.js"],
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

const workflowPath = join(root, ".github/workflows/protected-paths.yml");

test("the workflow is read from the base branch and never checks out the pull", () => {
  const workflow = readFileSync(workflowPath, "utf8");
  // pull_request would load this file from the pull, which could add `if: false` to the job
  assert.match(workflow, /\non:\n {2}pull_request_target:\n {4}types: \[opened, synchronize, reopened, ready_for_review, labeled, unlabeled\]\n/);
  assert.doesNotMatch(workflow, /^ {2}pull_request:/m);
  assert.doesNotMatch(workflow, /^\s+ref:/m);
  assert.doesNotMatch(workflow, /refs\/pull\//);
  assert.match(workflow, /git fetch --no-tags origin "\$HEAD_SHA"\n/);
  assert.match(workflow, /node scripts\/check-protected-paths\.js --base "\$BASE_SHA" --head "\$HEAD_SHA"/);
  assert.doesNotMatch(workflow, /cp scripts\/check-protected-paths\.js/);
  assert.match(workflow, /PR_AUTHOR_LOGIN:/);
  assert.match(workflow, /pull-requests:\s*read/);
});

// runs the `run:` block of the workflow in a clone whose tree is the base; the pull head
// exists only under refs/pull/34/head of origin, as on GitHub
function runWorkflowStep(headFiles) {
  const workflow = readFileSync(workflowPath, "utf8");
  const step = /\n {8}run: \|\n([\s\S]*)$/.exec(workflow);
  assert.ok(step, "the last step of the workflow is a run block");
  const body = step[1].replace(/^ {10}/gm, "");
  const origin = mkdtempSync(join(tmpdir(), "protected-paths-origin-"));
  const clone = mkdtempSync(join(tmpdir(), "protected-paths-clone-"));
  try {
    git(origin, "init", "-q", "-b", "main");
    git(origin, "config", "user.email", "t@example.test");
    git(origin, "config", "user.name", "t");
    git(origin, "config", "commit.gpgsign", "false");
    git(origin, "config", "uploadpack.allowAnySHA1InWant", "true");
    put(origin, "README.md", "x\n");
    put(origin, "scripts/check-protected-paths.js", readFileSync(script, "utf8"));
    git(origin, "add", "-A");
    git(origin, "commit", "-q", "-m", "init");
    const base = git(origin, "rev-parse", "HEAD");
    git(origin, "switch", "-q", "-c", "topic");
    for (const [file, text] of Object.entries(headFiles(workflow))) {
      put(origin, file, text);
    }
    git(origin, "add", "-A");
    git(origin, "commit", "-q", "-m", "topic");
    const head = git(origin, "rev-parse", "HEAD");
    git(origin, "update-ref", "refs/pull/34/head", head);
    git(origin, "switch", "-q", "main");
    git(origin, "branch", "-q", "-D", "topic");
    const cloned = spawnSync("git", ["clone", "-q", "--no-local", origin, clone], { encoding: "utf8" });
    assert.equal(cloned.status, 0, cloned.stderr);
    const probe = spawnSync("git", ["cat-file", "-t", head], { cwd: clone, encoding: "utf8" });
    assert.notEqual(probe.status, 0, "the clone starts without the pull head");
    return spawnSync("bash", ["-e", "-c", body], {
      cwd: clone,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${dirname(process.execPath)}:${process.env.PATH}`,
        BASE_SHA: base,
        HEAD_SHA: head,
        PR_NUMBER: "34",
        PR_AUTHOR_LOGIN: "pr-author",
        GITHUB_REPOSITORY: "repo-owner/repo",
        GITHUB_TOKEN: "",
      },
    });
  } finally {
    rmSync(origin, { recursive: true, force: true });
    rmSync(clone, { recursive: true, force: true });
  }
}

test("the workflow step reads a harmless pull from objects fetched into the base clone", () => {
  const result = runWorkflowStep(() => ({ "server.js": "ok\n" }));
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), "ok");
});

test("a pull that disables its own workflow and checker is still refused by the base checker", () => {
  const result = runWorkflowStep((workflow) => ({
    ".github/workflows/protected-paths.yml": workflow.replace(
      "    runs-on: ubuntu-latest",
      () => "    if: ${{ false }}\n    runs-on: ubuntu-latest",
    ),
    "scripts/check-protected-paths.js": "process.exit(0)\n",
  }));
  assert.equal(result.status, 1, result.stdout);
  assert.match(result.stderr, /\.github\/workflows\/protected-paths\.yml/);
  assert.match(result.stderr, /scripts\/check-protected-paths\.js/);
  assert.match(result.stderr, new RegExp(GATE_LABEL));
});

test("changing a gate file exits 1 without a verifier label", () => {
  for (const file of GATE_FILES) {
    const result = scenario({ [file]: "changed\n" });
    assert.equal(result.status, 1, file);
    assert.match(result.stderr, new RegExp(file.replace(/\./g, "\\.")));
    assert.match(result.stderr, new RegExp(GATE_LABEL));
  }
});

test("classifyHits splits agent config from gate files", () => {
  assert.deepEqual(
    classifyHits([".mcp.json", "scripts/verdict-gate.js", ".claude/x (symlink)"]),
    {
      agent: [".mcp.json", ".claude/x (symlink)"],
      gate: ["scripts/verdict-gate.js"],
    },
  );
});

const VERIFIER = { login: "app-pilote-verifier[bot]", type: "Bot" };
const OWNER = { login: "repo-owner", type: "User" };
const AUTHOR = { login: "pr-author", type: "User" };
const CURSOR_BOT = { login: "cursor[bot]", type: "Bot" };
const HEAD_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const OTHER_SHA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const MARKER = "<!-- dev-lead-verifier -->";

function labeled(actor) {
  return { event: "labeled", label: { name: GATE_LABEL }, actor };
}

function verdictComment(user, verdict, sha) {
  return { user, body: `VERDICT: ${verdict} @ ${sha}\n${MARKER}` };
}

function passOn(sha, user = VERIFIER) {
  return { headSha: sha, comments: [verdictComment(user, "PASS", sha)] };
}

test("gate-change-approved counts only when app-pilote-verifier[bot] labeled and PASSed the head", () => {
  assert.deepEqual(gateApprovalFromEvents([labeled(VERIFIER)], passOn(HEAD_SHA)), {
    ok: true,
    login: "app-pilote-verifier[bot]",
  });
  assert.equal(
    gateApprovalFromEvents([labeled(VERIFIER)], {
      headSha: HEAD_SHA,
      comments: [verdictComment(VERIFIER, "PASS+NOTES", HEAD_SHA)],
    }).ok,
    true,
  );
});

test("the label on the pull is ignored; only issue events count", () => {
  const decision = gateApprovalFromEvents([], { labels: [GATE_LABEL], ...passOn(HEAD_SHA) });
  assert.equal(decision.ok, false);
  assert.equal(decision.reason, "no-label");
});

test("a label from a human is refused", () => {
  assert.equal(gateApprovalFromEvents([labeled(OWNER)], passOn(HEAD_SHA)).reason, "not-verifier");
});

test("a label from the pull author is refused", () => {
  assert.equal(gateApprovalFromEvents([labeled(AUTHOR)], passOn(HEAD_SHA)).reason, "not-verifier");
});

test("a label from cursor[bot] is refused", () => {
  assert.equal(gateApprovalFromEvents([labeled(CURSOR_BOT)], passOn(HEAD_SHA)).reason, "not-verifier");
});

test("a verifier PASS on another SHA does not approve the head", () => {
  assert.equal(
    gateApprovalFromEvents([labeled(VERIFIER)], {
      headSha: HEAD_SHA,
      comments: [verdictComment(VERIFIER, "PASS", OTHER_SHA)],
    }).reason,
    "no-pass-for-head",
  );
});

test("unlabeling clears a previous verifier approval", () => {
  const decision = gateApprovalFromEvents(
    [labeled(VERIFIER), { event: "unlabeled", label: { name: GATE_LABEL }, actor: VERIFIER }],
    passOn(HEAD_SHA),
  );
  assert.equal(decision.ok, false);
  assert.equal(decision.reason, "no-label");
});

function jsonResponse(body, link) {
  return {
    ok: true,
    status: 200,
    headers: {
      get(name) {
        if (String(name).toLowerCase() === "link") {
          return link ?? null;
        }
        return null;
      },
    },
    json: async () => body,
  };
}

async function withGateHead(run) {
  const dir = mkdtempSync(join(tmpdir(), "check-protected-paths-"));
  const previous = process.cwd();
  try {
    git(dir, "init", "-q", "-b", "main");
    git(dir, "config", "user.email", "t@example.test");
    git(dir, "config", "user.name", "t");
    git(dir, "config", "commit.gpgsign", "false");
    put(dir, "README.md", "x\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "init");
    const base = git(dir, "rev-parse", "HEAD");
    put(dir, "scripts/verdict-gate.js", "changed\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "gate");
    const head = git(dir, "rev-parse", "HEAD");
    process.chdir(dir);
    return await run(base, head);
  } finally {
    process.chdir(previous);
    rmSync(dir, { recursive: true, force: true });
  }
}

const TIMELINE_URL = "https://api.github.com/repos/acme/app/issues/7/timeline?per_page=100";
const COMMENTS_URL = "https://api.github.com/repos/acme/app/issues/7/comments?per_page=100";

function gateFetch(events, comments) {
  return async (url) => {
    if (url === TIMELINE_URL) {
      return jsonResponse(events);
    }
    if (url === COMMENTS_URL) {
      return jsonResponse(comments);
    }
    throw new Error(`unexpected GET ${url}`);
  };
}

test("a verifier label and PASS on the head allows a gate file change", async () => {
  await withGateHead(async (base, head) => {
    const code = await main(["--base", base, "--head", head], {
      env: {
        GITHUB_TOKEN: "test-token",
        GITHUB_REPOSITORY: "acme/app",
        PR_NUMBER: "7",
        PR_AUTHOR_LOGIN: "pr-author",
      },
      fetch: gateFetch([labeled(VERIFIER)], [verdictComment(VERIFIER, "PASS", head)]),
    });
    assert.equal(code, 0);
  });
});

test("a gate change stays blocked when the author applied the label", async () => {
  await withGateHead(async (base, head) => {
    const code = await main(["--base", base, "--head", head], {
      env: {
        GITHUB_TOKEN: "test-token",
        GITHUB_REPOSITORY: "acme/app",
        PR_NUMBER: "7",
        PR_AUTHOR_LOGIN: "pr-author",
      },
      fetch: gateFetch([labeled(AUTHOR)], [verdictComment(VERIFIER, "PASS", head)]),
    });
    assert.equal(code, 1);
  });
});

test("a commit pushed after the label with an earlier commit date loses the approval", async () => {
  const dir = mkdtempSync(join(tmpdir(), "check-protected-paths-"));
  const previous = process.cwd();
  try {
    git(dir, "init", "-q", "-b", "main");
    git(dir, "config", "user.email", "t@example.test");
    git(dir, "config", "user.name", "t");
    git(dir, "config", "commit.gpgsign", "false");
    put(dir, "README.md", "x\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "init");
    const base = git(dir, "rev-parse", "HEAD");
    put(dir, "scripts/verdict-gate.js", "changed\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "gate");
    const shaA = git(dir, "rev-parse", "HEAD");
    put(dir, "scripts/verdict-gate.js", "again\n");
    git(dir, "add", "-A");
    const dated = spawnSync(
      "git",
      ["-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "backdated"],
      {
        cwd: dir,
        encoding: "utf8",
        env: {
          ...process.env,
          GIT_AUTHOR_DATE: "2019-01-01T00:00:00Z",
          GIT_COMMITTER_DATE: "2019-01-01T00:00:00Z",
        },
      },
    );
    assert.equal(dated.status, 0, dated.stderr);
    const shaB = git(dir, "rev-parse", "HEAD");
    assert.notEqual(shaA, shaB);
    process.chdir(dir);
    const code = await main(["--base", base, "--head", shaB], {
      env: {
        GITHUB_TOKEN: "test-token",
        GITHUB_REPOSITORY: "acme/app",
        PR_NUMBER: "7",
        PR_AUTHOR_LOGIN: "pr-author",
      },
      fetch: gateFetch([labeled(VERIFIER)], [verdictComment(VERIFIER, "PASS", shaA)]),
    });
    assert.equal(code, 1);
  } finally {
    process.chdir(previous);
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a verifier label does not waive an agent-config change", () => {
  const result = scenario({ ".mcp.json": "{}\n" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /\.mcp\.json/);
  assert.doesNotMatch(result.stderr, new RegExp(GATE_LABEL));
});
