"use strict";

const { readFileSync } = require("node:fs");

const MARKER = "<!-- dev-lead-verifier -->";
const STATUS_CONTEXT = "verdict-gate";
const VERDICT_LINE = /^VERDICT: (PASS\+NOTES|PASS|FAIL) @ ([0-9a-fA-F]{40})$/;
const DESCRIPTION_MAX = 140;
const UNREADABLE_DESCRIPTION = "could not read PR comments";
const HEX_SHA = /^[0-9a-fA-F]{40}$/;
const VERIFIERS = Object.freeze([
  Object.freeze({ login: "app-pilote-verifier[bot]", type: "Bot" }),
]);

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

function requireComment(comment) {
  if (
    comment == null ||
    typeof comment.id !== "string" ||
    !/^[0-9]+$/.test(comment.id) ||
    typeof comment.createdAtMs !== "number" ||
    !Number.isFinite(comment.createdAtMs) ||
    typeof comment.body !== "string"
  ) {
    throw new Error(
      "comment must have a decimal id, a finite createdAtMs, and a string body",
    );
  }
}

function fenceOpen(line) {
  const match = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
  if (!match) {
    return null;
  }
  return {
    char: match[2][0],
    len: match[2].length,
    rest: match[3],
  };
}

function isClosingFence(line, fence) {
  const open = fenceOpen(line);
  return (
    open != null &&
    open.char === fence.char &&
    open.len >= fence.len &&
    open.rest.trim() === ""
  );
}

function plainLines(body) {
  const lines = [];
  let fence = null;
  let inQuote = false;
  for (const rawLine of String(body).split("\n")) {
    const line = rawLine.replace(/\r$/, "");
    if (fence) {
      if (isClosingFence(line, fence)) {
        fence = null;
      }
      continue;
    }
    if (line.trim() === "") {
      inQuote = false;
      lines.push(line);
      continue;
    }
    if (/^ {0,3}>/.test(line)) {
      inQuote = true;
      continue;
    }
    if (inQuote) {
      const open = fenceOpen(line);
      if (open) {
        inQuote = false;
        fence = open;
      }
      continue;
    }
    const open = fenceOpen(line);
    if (open) {
      fence = open;
      continue;
    }
    if (/^(?: {4}|\t)/.test(line)) {
      continue;
    }
    lines.push(line);
  }
  return lines;
}

function withoutCodeSpans(text) {
  let out = "";
  let index = 0;
  while (index < text.length) {
    if (text[index] !== "`") {
      out += text[index];
      index += 1;
      continue;
    }
    let size = 1;
    while (text[index + size] === "`") {
      size += 1;
    }
    const close = text.indexOf("`".repeat(size), index + size);
    if (close === -1) {
      out += text.slice(index);
      break;
    }
    if (text.slice(index + size, close).includes("\n")) {
      out += "\n";
    }
    index = close + size;
  }
  return out;
}

function prose(body) {
  return withoutCodeSpans(plainLines(body).join("\n"));
}

function verdictLines(body) {
  const found = [];
  for (const line of prose(body).split("\n")) {
    const match = VERDICT_LINE.exec(line);
    if (match) {
      found.push({ verdict: match[1], sha: match[2].toLowerCase() });
    }
  }
  return found;
}

function plainMarker(body) {
  return prose(body).includes(MARKER);
}

function isNewer(comment, winner) {
  if (comment.createdAtMs !== winner.createdAtMs) {
    return comment.createdAtMs > winner.createdAtMs;
  }
  return BigInt(comment.id) > BigInt(winner.id);
}

function noneDescription(hint, headSha) {
  if (hint === "line-without-marker") {
    return `VERDICT line missing ${MARKER} for ${headSha}`;
  }
  if (hint === "marker-without-line") {
    return `marker present but no VERDICT line for ${headSha}`;
  }
  return `no marked VERDICT for ${headSha}`;
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

function readType(user) {
  if (user == null || typeof user !== "object" || typeof user.type !== "string") {
    return null;
  }
  return user.type;
}

function nonEmpty(value) {
  return typeof value === "string" && value !== "";
}

// absent list: default; invalid list or entry: empty (fail closed)
function usableVerifiers(verifiers) {
  if (verifiers == null) {
    return VERIFIERS;
  }
  if (
    !Array.isArray(verifiers) ||
    !verifiers.every(
      (entry) => entry != null && nonEmpty(entry.login) && nonEmpty(entry.type),
    )
  ) {
    return [];
  }
  return verifiers;
}

function isVerifier(comment, verifiers) {
  if (comment == null || comment.user == null) {
    return false;
  }
  const { login, type } = comment.user;
  return verifiers.some((entry) => entry.login === login && entry.type === type);
}

function foldLogin(value) {
  if (typeof value !== "string" || value === "") {
    return null;
  }
  return value.toLowerCase();
}

function decide(input) {
  const headSha = requireHead(input.headSha);
  const verifiers = usableVerifiers(input.verifiers);
  let seenLine = false;
  let seenMarker = false;
  let winner = null;

  for (const comment of input.comments) {
    if (!isVerifier(comment, verifiers)) {
      continue;
    }
    requireComment(comment);
    const lines = verdictLines(comment.body);
    const hasMarker = plainMarker(comment.body);
    if (lines.length > 0) {
      seenLine = true;
    }
    if (hasMarker) {
      seenMarker = true;
    }
    if (!hasMarker || lines.length === 0) {
      continue;
    }
    if (winner == null || isNewer(comment, winner)) {
      winner = {
        id: comment.id,
        createdAtMs: comment.createdAtMs,
        lines,
        login: foldLogin(readLogin(comment.user)),
      };
    }
  }

  if (winner == null) {
    let hint = "neither";
    if (seenLine) {
      hint = "line-without-marker";
    } else if (seenMarker) {
      hint = "marker-without-line";
    }
    return {
      kind: "fail",
      reason: { code: "none", headSha, hint },
      description: render(noneDescription(hint, headSha)),
    };
  }

  const first = winner.lines[0];
  const agrees = winner.lines.every(
    (line) => line.verdict === first.verdict && line.sha === first.sha,
  );
  if (!agrees) {
    return {
      kind: "fail",
      reason: { code: "conflicting-lines", headSha, commentId: winner.id },
      description: render("latest marked comment has conflicting VERDICT lines"),
    };
  }

  if (first.sha !== headSha) {
    return {
      kind: "fail",
      reason: {
        code: "sha-mismatch",
        verdict: first.verdict,
        citedSha: first.sha,
        headSha,
        commentId: winner.id,
      },
      description: render(
        `VERDICT ${first.verdict} @ ${first.sha} does not match head ${headSha}`,
      ),
    };
  }

  const authorLogin = foldLogin(input.authorLogin);
  if (authorLogin == null) {
    return {
      kind: "fail",
      reason: {
        code: "missing-login",
        headSha,
        commentId: winner.id,
        side: "pull",
      },
      description: render("pull request has no author login"),
    };
  }
  if (winner.login === authorLogin) {
    return {
      kind: "fail",
      reason: {
        code: "author-match",
        headSha,
        commentId: winner.id,
        authorLogin,
      },
      description: render(`author ${authorLogin} wrote the marked VERDICT`),
    };
  }

  if (first.verdict === "FAIL") {
    return {
      kind: "fail",
      reason: { code: "verdict-fail", headSha, commentId: winner.id },
      description: render(`VERDICT FAIL @ ${headSha}`),
    };
  }

  return {
    kind: "pass",
    verdict: first.verdict,
    sha: first.sha,
    commentId: winner.id,
    description: render(`VERDICT ${first.verdict} @ ${first.sha}`),
  };
}

function apiHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2026-03-10",
    "User-Agent": "verdict-gate",
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

function decimalId(id) {
  if (typeof id === "string" && /^[0-9]+$/.test(id)) {
    return id;
  }
  if (typeof id === "number" && Number.isSafeInteger(id) && id >= 0) {
    return String(id);
  }
  return null;
}

function toComment(raw) {
  if (raw == null || typeof raw !== "object") {
    throw new Error("comment page is unreadable");
  }
  const id = decimalId(raw.id);
  const createdAtMs = Date.parse(raw.created_at);
  if (id == null || !Number.isFinite(createdAtMs) || typeof raw.body !== "string") {
    throw new Error("comment page is unreadable");
  }
  return {
    id,
    createdAtMs,
    body: raw.body,
    user: { login: readLogin(raw.user), type: readType(raw.user) },
  };
}

async function loadComments(io, token, owner, repo, number) {
  const comments = [];
  let url = `https://api.github.com/repos/${owner}/${repo}/issues/${number}/comments?per_page=100`;
  while (url) {
    const response = await githubGet(io, token, url);
    const page = await response.json();
    if (!Array.isArray(page)) {
      throw new Error("comment page is unreadable");
    }
    for (const raw of page) {
      comments.push(toComment(raw));
    }
    url = nextUrl(response.headers.get("link"));
  }
  return comments;
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
  io.stderr(description);
  return 0;
}

function repositoryParts(repository) {
  const parts = repository.split("/");
  if (parts.length !== 2 || parts[0] === "" || parts[1] === "") {
    return null;
  }
  return { owner: parts[0], repo: parts[1] };
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
    const sha = pull && pull.head ? pull.head.sha : undefined;
    return {
      action: "ready",
      number: issue.number,
      sha,
      authorLogin: readLogin(pull && pull.user),
    };
  }
  if (eventName === "pull_request") {
    const pullRequest = payload.pull_request;
    const sha =
      pullRequest && pullRequest.head ? pullRequest.head.sha : undefined;
    const number = pullRequest ? pullRequest.number : undefined;
    return {
      action: "ready",
      number,
      sha,
      authorLogin: readLogin(pullRequest && pullRequest.user),
    };
  }
  return { action: "exit", code: 1 };
}

async function main(argv = process.argv.slice(2), io = defaultIo) {
  if (argv.length > 0) {
    io.stderr("usage: verdict-gate.js");
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
    return postStatus(
      io,
      token,
      names.owner,
      names.repo,
      headSha,
      "failure",
      UNREADABLE_DESCRIPTION,
    );
  }

  const decision = decide({
    headSha,
    comments,
    authorLogin: head.authorLogin,
    verifiers: io.verifiers,
  });
  const state = decision.kind === "pass" ? "success" : "failure";
  return postStatus(
    io,
    token,
    names.owner,
    names.repo,
    headSha,
    state,
    decision.description,
  );
}

const defaultIo = {
  env: process.env,
  readFile(path) {
    return readFileSync(path, "utf8");
  },
  fetch(url, init) {
    return globalThis.fetch(url, init);
  },
  stderr(line) {
    console.error(line);
  },
};

module.exports = { decide, main };

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
