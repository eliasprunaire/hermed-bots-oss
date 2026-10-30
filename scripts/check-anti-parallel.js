"use strict";

const { spawnSync } = require("node:child_process");
const { readFileSync } = require("node:fs");

const MARKER = "<!-- dev-lead-verifier -->";
const VERDICT_LINE = /^VERDICT: (PASS\+NOTES|PASS|FAIL) @ ([0-9a-fA-F]{40})$/;
const HEX_SHA = /^[0-9a-fA-F]{40}$/;
const BC_UUID =
  /(?<![A-Za-z0-9])bc-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9a-fA-F-])/gi;
const ACTIVE_RUN = new Set([
  "in_progress",
  "queued",
  "waiting",
  "pending",
  "requested",
]);
const SIGNALER_LOGIN = "cursor[bot]";
const DESCRIPTION_MAX = 140;
const STATUS_CONTEXT = "anti-parallel";

function render(text) {
  if (text.length > DESCRIPTION_MAX) {
    throw new Error(`description is ${text.length} characters`);
  }
  return text;
}

function requireHead(headSha) {
  if (typeof headSha !== "string" || !HEX_SHA.test(headSha)) {
    throw new Error("headSha must be 40 hex digits");
  }
  return headSha.toLowerCase();
}

function nonEmpty(value) {
  return typeof value === "string" && value !== "";
}

function foldLogin(user) {
  if (user == null || typeof user !== "object" || !nonEmpty(user.login)) {
    return null;
  }
  return user.login.toLowerCase();
}

function isSignaler(comment) {
  return foldLogin(comment && comment.user) === SIGNALER_LOGIN;
}

function markedVerdicts(body) {
  const text = String(body ?? "");
  if (!text.includes(MARKER)) {
    return [];
  }
  const found = [];
  for (const raw of text.split("\n")) {
    const match = VERDICT_LINE.exec(raw.replace(/\r$/, ""));
    if (match) {
      found.push({ verdict: match[1], sha: match[2].toLowerCase() });
    }
  }
  return found;
}

function runPath(run) {
  if (run == null || typeof run !== "object") {
    return "";
  }
  if (nonEmpty(run.path)) {
    return run.path.replace(/\\/g, "/").toLowerCase();
  }
  if (run.workflow != null && nonEmpty(run.workflow.path)) {
    return run.workflow.path.replace(/\\/g, "/").toLowerCase();
  }
  return "";
}

function isVerifierWorkflow(run) {
  const path = runPath(run);
  if (path === "verdict-gate.yml" || path.endsWith("/verdict-gate.yml")) {
    return true;
  }
  const name =
    run != null && typeof run.name === "string" ? run.name.trim().toLowerCase() : "";
  return name === "verdict gate";
}

function decideVerifier(input) {
  const headSha = requireHead(input.headSha);
  if (!Array.isArray(input.comments)) {
    return {
      kind: "fail",
      reason: { code: "unreadable", headSha },
      description: render("could not read PR comments"),
    };
  }
  const citing = [];
  for (const comment of input.comments) {
    if (comment == null || typeof comment !== "object" || isSignaler(comment)) {
      continue;
    }
    if (typeof comment.body !== "string") {
      return {
        kind: "fail",
        reason: { code: "unreadable", headSha },
        description: render("could not read PR comments"),
      };
    }
    const citesHead = markedVerdicts(comment.body).some(
      (line) => line.sha === headSha,
    );
    if (citesHead) {
      citing.push(comment);
    }
  }
  if (citing.length > 1) {
    return {
      kind: "fail",
      reason: {
        code: "parallel-verdicts",
        headSha,
        count: citing.length,
      },
      description: render(`multiple marked VERDICT comments for ${headSha}`),
    };
  }
  if (!Array.isArray(input.runs)) {
    return {
      kind: "fail",
      reason: { code: "unreadable-runs", headSha },
      description: render("could not read verifier runs"),
    };
  }
  const active = [];
  for (const run of input.runs) {
    if (run == null || typeof run !== "object" || !isVerifierWorkflow(run)) {
      continue;
    }
    const status =
      typeof run.status === "string" ? run.status.toLowerCase() : "";
    if (ACTIVE_RUN.has(status) && runBelongsToPr(run, headSha, input.number)) {
      active.push(run);
    }
  }
  if (active.length > 1) {
    return {
      kind: "fail",
      reason: {
        code: "verifier-in-progress",
        headSha,
        count: active.length,
      },
      description: render(`concurrent verifier runs for ${headSha}`),
    };
  }
  return {
    kind: "pass",
    description: render(`one verifier for ${headSha}`),
  };
}

function runBelongsToPr(run, headSha, number) {
  const sha = typeof run.headSha === "string" ? run.headSha.toLowerCase() : "";
  if (sha === headSha) {
    return true;
  }
  const event = typeof run.event === "string" ? run.event.toLowerCase() : "";
  if (event !== "issue_comment") {
    return false;
  }
  if (typeof number === "number" && Array.isArray(run.pullNumbers)) {
    if (run.pullNumbers.includes(number)) {
      return true;
    }
  }
  const title = typeof run.displayTitle === "string" ? run.displayTitle : "";
  return (
    typeof number === "number" &&
    new RegExp(`(?:^|\\s)pr-${number}(?![0-9])`).test(title)
  );
}

function identitiesOf(message) {
  const found = [];
  const seen = new Set();
  for (const match of String(message ?? "").matchAll(BC_UUID)) {
    const id = match[0].toLowerCase();
    if (!seen.has(id)) {
      seen.add(id);
      found.push(id);
    }
  }
  return found;
}

function rangesOverlap(a, b) {
  return a.min <= b.max && b.min <= a.max;
}

function decideExecutor(input) {
  if (!Array.isArray(input.commits)) {
    return {
      kind: "fail",
      reason: { code: "unreadable-commits" },
      description: render("could not read PR commits"),
    };
  }
  const ranges = new Map();
  for (const commit of input.commits) {
    if (commit == null || typeof commit !== "object") {
      return {
        kind: "fail",
        reason: { code: "unreadable-commits" },
        description: render("could not read PR commits"),
      };
    }
    const t = Number.isFinite(commit.authoredAtMs) ? commit.authoredAtMs : 0;
    for (const id of identitiesOf(commit.message)) {
      const prev = ranges.get(id);
      if (prev == null) {
        ranges.set(id, { min: t, max: t });
      } else {
        prev.min = Math.min(prev.min, t);
        prev.max = Math.max(prev.max, t);
      }
    }
  }
  const ids = [...ranges.keys()].sort();
  if (ids.length <= 1) {
    return { kind: "pass", description: render("one executor") };
  }
  for (let i = 0; i < ids.length; i += 1) {
    for (let j = i + 1; j < ids.length; j += 1) {
      if (rangesOverlap(ranges.get(ids[i]), ranges.get(ids[j]))) {
        return {
          kind: "fail",
          reason: { code: "parallel-executors", count: ids.length },
          description: render("multiple executor identities in one run window"),
        };
      }
    }
  }
  return { kind: "pass", description: render("one executor") };
}

function apiHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2026-03-10",
    "User-Agent": "anti-parallel-lock",
  };
}

async function githubGet(io, token, url) {
  const headers = apiHeaders(token);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await io.fetch(url, { headers });
      if (response && response.ok) {
        return response;
      }
    } catch {
      continue;
    }
  }
  throw new Error("request failed");
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

async function loadPages(io, token, startUrl) {
  const pages = [];
  let url = startUrl;
  while (url) {
    const response = await githubGet(io, token, url);
    const page = await response.json();
    if (!Array.isArray(page)) {
      throw new Error("page is unreadable");
    }
    pages.push(page);
    url = nextUrl(response.headers.get("link"));
  }
  return pages;
}

function toComment(raw) {
  if (raw == null || typeof raw !== "object" || typeof raw.body !== "string") {
    throw new Error("comment page is unreadable");
  }
  const login =
    raw.user != null && typeof raw.user === "object" ? raw.user.login : undefined;
  return {
    body: raw.body,
    user: nonEmpty(login) ? { login } : null,
  };
}

async function loadComments(io, token, owner, repo, number) {
  const comments = [];
  const pages = await loadPages(
    io,
    token,
    `https://api.github.com/repos/${owner}/${repo}/issues/${number}/comments?per_page=100`,
  );
  for (const page of pages) {
    for (const raw of page) {
      comments.push(toComment(raw));
    }
  }
  return comments;
}

function toRun(raw) {
  if (raw == null || typeof raw !== "object") {
    throw new Error("run page is unreadable");
  }
  const pullNumbers = [];
  if (Array.isArray(raw.pull_requests)) {
    for (const pull of raw.pull_requests) {
      if (
        pull != null &&
        typeof pull === "object" &&
        typeof pull.number === "number" &&
        Number.isInteger(pull.number) &&
        pull.number > 0
      ) {
        pullNumbers.push(pull.number);
      }
    }
  }
  return {
    id: typeof raw.id === "number" ? raw.id : 0,
    headSha: typeof raw.head_sha === "string" ? raw.head_sha : "",
    status: typeof raw.status === "string" ? raw.status : "",
    path: typeof raw.path === "string" ? raw.path : "",
    name: typeof raw.name === "string" ? raw.name : "",
    event: typeof raw.event === "string" ? raw.event : "",
    displayTitle: typeof raw.display_title === "string" ? raw.display_title : "",
    pullNumbers,
    workflow:
      raw.workflow != null && typeof raw.workflow === "object"
        ? { path: raw.workflow.path }
        : undefined,
  };
}

async function loadRunPages(io, token, startUrl) {
  const runs = [];
  let url = startUrl;
  while (url) {
    const response = await githubGet(io, token, url);
    const page = await response.json();
    const list =
      page != null && Array.isArray(page.workflow_runs)
        ? page.workflow_runs
        : null;
    if (list == null) {
      throw new Error("run page is unreadable");
    }
    for (const raw of list) {
      runs.push(toRun(raw));
    }
    url = nextUrl(response.headers.get("link"));
  }
  return runs;
}

async function loadRuns(io, token, owner, repo, headSha) {
  const byHead = await loadRunPages(
    io,
    token,
    `https://api.github.com/repos/${owner}/${repo}/actions/runs?head_sha=${headSha}&per_page=100`,
  );
  const byComment = [];
  for (const status of ACTIVE_RUN) {
    const page = await loadRunPages(
      io,
      token,
      `https://api.github.com/repos/${owner}/${repo}/actions/workflows/verdict-gate.yml/runs?event=issue_comment&status=${status}&per_page=100`,
    );
    byComment.push(...page);
  }
  const seen = new Set();
  const runs = [];
  for (const run of [...byHead, ...byComment]) {
    const key = run.id !== 0 ? `id:${run.id}` : `sha:${run.headSha}:${run.status}:${run.event}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    runs.push(run);
  }
  return runs;
}

function parseCommits(stdout) {
  const commits = [];
  const chunks = String(stdout ?? "").split("\0");
  for (let i = 0; i + 1 < chunks.length; i += 2) {
    const stamp = chunks[i].trim();
    const message = chunks[i + 1];
    if (stamp === "" && message === "") {
      continue;
    }
    const authoredAtMs = Date.parse(stamp);
    commits.push({
      message,
      authoredAtMs: Number.isFinite(authoredAtMs) ? authoredAtMs : 0,
    });
  }
  return commits;
}

function loadCommits(io, baseSha, headSha) {
  if (!nonEmpty(baseSha) || !HEX_SHA.test(baseSha) || !HEX_SHA.test(headSha)) {
    return [];
  }
  const result = io.run([
    "git",
    "log",
    "--format=%aI%x00%B%x00",
    `${baseSha.toLowerCase()}..${headSha.toLowerCase()}`,
  ]);
  if (result == null || result.status !== 0) {
    throw new Error("could not read PR commits");
  }
  return parseCommits(result.stdout);
}

function repositoryParts(repository) {
  const parts = repository.split("/");
  if (parts.length !== 2 || parts[0] === "" || parts[1] === "") {
    return null;
  }
  return { owner: parts[0], repo: parts[1] };
}

function readHeadSha(pull) {
  const sha = pull && pull.head ? pull.head.sha : undefined;
  if (typeof sha === "string" && HEX_SHA.test(sha)) {
    return sha.toLowerCase();
  }
  return null;
}

function readBaseSha(pull) {
  const sha = pull && pull.base ? pull.base.sha : undefined;
  if (typeof sha === "string" && HEX_SHA.test(sha)) {
    return sha.toLowerCase();
  }
  return null;
}

async function resolveHead(io, token, owner, repo, eventName, payload) {
  if (eventName === "issue_comment") {
    const issue = payload.issue;
    if (issue == null || issue.pull_request == null) {
      return { action: "exit", code: 0 };
    }
    let response;
    try {
      response = await githubGet(
        io,
        token,
        `https://api.github.com/repos/${owner}/${repo}/pulls/${issue.number}`,
      );
    } catch {
      return { action: "exit", code: 1 };
    }
    let pull;
    try {
      pull = await response.json();
    } catch {
      return { action: "exit", code: 1 };
    }
    return {
      action: "ready",
      number: issue.number,
      sha: readHeadSha(pull),
      baseSha: readBaseSha(pull),
      checkCommits: false,
    };
  }
  if (eventName === "pull_request" || eventName === "pull_request_target") {
    const pullRequest = payload.pull_request;
    const number = pullRequest ? pullRequest.number : undefined;
    return {
      action: "ready",
      number,
      sha: readHeadSha(pullRequest),
      baseSha: readBaseSha(pullRequest),
      checkCommits: true,
    };
  }
  return { action: "exit", code: 1 };
}

async function postStatus(io, token, owner, repo, sha, state, description) {
  let response;
  try {
    response = await io.fetch(
      `https://api.github.com/repos/${owner}/${repo}/statuses/${sha}`,
      {
        method: "POST",
        headers: {
          ...apiHeaders(token),
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          state,
          context: STATUS_CONTEXT,
          description,
        }),
      },
    );
  } catch {
    return 1;
  }
  if (!response || response.status !== 201) {
    return 1;
  }
  return 0;
}

async function report(io, token, owner, repo, sha, decision) {
  const state = decision.kind === "pass" ? "success" : "failure";
  const posted = await postStatus(
    io,
    token,
    owner,
    repo,
    sha,
    state,
    decision.description,
  );
  io.stderr(decision.description);
  if (posted !== 0) {
    return 1;
  }
  if (io.env.GITHUB_EVENT_NAME === "issue_comment") {
    return 0;
  }
  return decision.kind === "pass" ? 0 : 1;
}

async function main(argv = process.argv.slice(2), io = defaultIo) {
  if (argv.length > 0) {
    io.stderr("usage: check-anti-parallel.js");
    return 1;
  }
  const token = io.env.GITHUB_TOKEN;
  const eventPath = io.env.GITHUB_EVENT_PATH;
  const repository = io.env.GITHUB_REPOSITORY;
  const eventName = io.env.GITHUB_EVENT_NAME;
  if (!token || !eventPath || !repository || !eventName) {
    return 1;
  }
  const names = repositoryParts(repository);
  if (names == null) {
    return 1;
  }
  let payload;
  try {
    payload = JSON.parse(io.readFile(eventPath));
  } catch {
    return 1;
  }
  if (payload == null || typeof payload !== "object") {
    return 1;
  }

  const head = await resolveHead(
    io,
    token,
    names.owner,
    names.repo,
    eventName,
    payload,
  );
  if (head.action === "exit") {
    return head.code;
  }
  if (typeof head.sha !== "string" || !HEX_SHA.test(head.sha)) {
    return 1;
  }
  const headSha = head.sha.toLowerCase();

  let comments;
  try {
    comments = await loadComments(
      io,
      token,
      names.owner,
      names.repo,
      head.number,
    );
  } catch {
    return report(io, token, names.owner, names.repo, headSha, {
      kind: "fail",
      description: render("could not read PR comments"),
    });
  }

  let runs;
  try {
    runs = await loadRuns(io, token, names.owner, names.repo, headSha);
  } catch {
    return report(io, token, names.owner, names.repo, headSha, {
      kind: "fail",
      description: render("could not read verifier runs"),
    });
  }

  const verifier = decideVerifier({
    headSha,
    number: head.number,
    comments,
    runs,
  });
  if (verifier.kind !== "pass") {
    return report(io, token, names.owner, names.repo, headSha, verifier);
  }

  if (head.checkCommits) {
    let commits;
    try {
      commits = loadCommits(io, head.baseSha, headSha);
    } catch {
      return report(io, token, names.owner, names.repo, headSha, {
        kind: "fail",
        description: render("could not read PR commits"),
      });
    }
    const executor = decideExecutor({ commits });
    if (executor.kind !== "pass") {
      return report(io, token, names.owner, names.repo, headSha, executor);
    }
    io.stderr(executor.description);
  }

  return report(io, token, names.owner, names.repo, headSha, verifier);
}

const defaultIo = {
  env: process.env,
  readFile(path) {
    return readFileSync(path, "utf8");
  },
  fetch(url, init) {
    return globalThis.fetch(url, init);
  },
  run(argv, input) {
    const result = spawnSync(argv[0], argv.slice(1), {
      encoding: "utf8",
      input,
      maxBuffer: 32 * 1024 * 1024,
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    });
    return {
      status: result.status == null ? 1 : result.status,
      stdout: result.stdout || "",
    };
  },
  stderr(line) {
    console.error(line);
  },
};

module.exports = { decideExecutor, decideVerifier, main, STATUS_CONTEXT };

if (require.main === module) {
  main()
    .then((code) => {
      process.exitCode = code;
    })
    .catch((err) => {
      console.error(err instanceof Error ? err.message : String(err));
      process.exitCode = 1;
    });
}
