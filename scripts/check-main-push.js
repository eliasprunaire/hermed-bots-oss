"use strict";

const LIST_API_VERSION = "2026-03-10";
const PULL_API_VERSION = "2022-11-28";
const HEX_SHA = /^[0-9a-fA-F]{40}$/;
const REPOSITORY = /^[^/\s]+\/[^/\s]+$/;
const ZERO_SHA = "0".repeat(40);

function defaultIo() {
  return {
    env: process.env,
    fetch: globalThis.fetch,
    stderr(line) {
      console.error(line);
    },
  };
}

function headers(token, version) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": version,
    "User-Agent": "check-main-push",
  };
}

function sameSha(value, sha) {
  return typeof value === "string" && HEX_SHA.test(value) && value.toLowerCase() === sha;
}

function pullNumber(item) {
  return typeof item.number === "number" && Number.isInteger(item.number) && item.number > 0
    ? item.number
    : null;
}

function targetsMain(item) {
  const base = item.base;
  if (base != null && (typeof base !== "object" || Array.isArray(base))) {
    return "malformed";
  }
  return base != null && base.ref === "main" ? "main" : "other";
}

function classify(body, sha) {
  if (!Array.isArray(body)) {
    return { kind: "malformed" };
  }
  const lookups = [];
  let merged = false;
  for (const item of body) {
    if (item == null || typeof item !== "object" || Array.isArray(item)) {
      return { kind: "malformed" };
    }
    const baseKind = targetsMain(item);
    if (baseKind === "malformed") {
      return { kind: "malformed" };
    }
    if (typeof item.merged_at !== "string" || item.merged_at === "" || baseKind !== "main") {
      continue;
    }
    if (item.merge_commit_sha == null || item.merge_commit_sha === "") {
      const number = pullNumber(item);
      if (number == null) {
        return { kind: "malformed" };
      }
      lookups.push(number);
      continue;
    }
    if (sameSha(item.merge_commit_sha, sha)) {
      merged = true;
    }
  }
  if (merged) {
    return { kind: "merged" };
  }
  if (lookups.length > 0) {
    return { kind: "lookup", numbers: lookups };
  }
  return { kind: "unmatched" };
}

function firstParent(body) {
  if (body == null || typeof body !== "object" || Array.isArray(body)) {
    return { kind: "malformed" };
  }
  if (!Array.isArray(body.parents)) {
    return { kind: "malformed" };
  }
  if (body.parents.length === 0) {
    return { kind: "unmatched" };
  }
  const parent = body.parents[0];
  if (parent == null || typeof parent !== "object" || Array.isArray(parent)) {
    return { kind: "malformed" };
  }
  if (typeof parent.sha !== "string" || !HEX_SHA.test(parent.sha)) {
    return { kind: "malformed" };
  }
  return { kind: "ok", sha: parent.sha.toLowerCase() };
}

const UNKNOWN = "UNKNOWN";
const NONCOMPLIANT = "NONCOMPLIANT";

function fail(io, status, message) {
  io.stderr(`${status}: ${message}`);
  return 1;
}

async function readJson(io, url, token, version, failMessage) {
  let response;
  try {
    response = await io.fetch(url, { headers: headers(token, version) });
  } catch {
    fail(io, UNKNOWN, failMessage);
    return { ok: false };
  }
  if (response == null || response.ok !== true) {
    fail(io, UNKNOWN, failMessage);
    return { ok: false };
  }
  try {
    return { ok: true, body: await response.json() };
  } catch {
    return { ok: true, body: undefined, jsonFailed: true };
  }
}

function matchesMergeCommit(body, sha) {
  if (body == null || typeof body !== "object" || Array.isArray(body)) {
    return "malformed";
  }
  const baseKind = targetsMain(body);
  if (baseKind === "malformed") {
    return "malformed";
  }
  if (
    typeof body.merged_at === "string" &&
    body.merged_at !== "" &&
    sameSha(body.merge_commit_sha, sha) &&
    baseKind === "main"
  ) {
    return "merged";
  }
  return "unmatched";
}

async function main(io = defaultIo()) {
  const repository = io.env.GITHUB_REPOSITORY;
  let sha = io.env.GITHUB_SHA;
  let before = io.env.GITHUB_BEFORE;
  const token = io.env.GITHUB_TOKEN;
  const api = String(io.env.GITHUB_API_URL || "https://api.github.com").replace(
    /\/$/,
    "",
  );
  if (typeof repository !== "string" || !REPOSITORY.test(repository)) {
    return fail(io, UNKNOWN, "GITHUB_REPOSITORY must be owner/repo");
  }
  if (typeof sha !== "string" || !HEX_SHA.test(sha)) {
    return fail(io, UNKNOWN, "GITHUB_SHA must be 40 hex digits");
  }
  sha = sha.toLowerCase();
  if (typeof before !== "string" || !HEX_SHA.test(before) || before.toLowerCase() === ZERO_SHA) {
    return fail(io, UNKNOWN, "GITHUB_BEFORE must be a non-zero sha");
  }
  before = before.toLowerCase();
  if (typeof token !== "string" || token === "") {
    return fail(io, UNKNOWN, "GITHUB_TOKEN is required");
  }
  const [owner, repo] = repository.split("/");
  const encoded = `${encodeURIComponent(owner)}/${encodeURIComponent(repo)}`;
  const pullsUrl = `${api}/repos/${encoded}/commits/${encodeURIComponent(sha)}/pulls`;
  const commitUrl = `${api}/repos/${encoded}/commits/${encodeURIComponent(sha)}`;
  const pulls = await readJson(
    io,
    pullsUrl,
    token,
    LIST_API_VERSION,
    "could not read pull requests for the commit",
  );
  if (!pulls.ok) {
    return 1;
  }
  if (pulls.jsonFailed) {
    return fail(io, UNKNOWN, "malformed pull request list");
  }
  const listed = classify(pulls.body, sha);
  if (listed.kind === "malformed") {
    return fail(io, UNKNOWN, "malformed pull request list");
  }
  let merged = listed.kind === "merged";
  if (listed.kind === "lookup") {
    for (const number of listed.numbers) {
      const detail = await readJson(
        io,
        `${api}/repos/${encoded}/pulls/${encodeURIComponent(String(number))}`,
        token,
        PULL_API_VERSION,
        "could not read the pull request",
      );
      if (!detail.ok) {
        return 1;
      }
      if (detail.jsonFailed) {
        return fail(io, UNKNOWN, "malformed pull request");
      }
      const match = matchesMergeCommit(detail.body, sha);
      if (match === "malformed") {
        return fail(io, UNKNOWN, "malformed pull request");
      }
      if (match === "merged") {
        merged = true;
        break;
      }
    }
  }
  if (!merged) {
    return fail(io, NONCOMPLIANT, `no merged pull request for ${sha}`);
  }
  const commit = await readJson(
    io,
    commitUrl,
    token,
    LIST_API_VERSION,
    "could not read the commit",
  );
  if (!commit.ok) {
    return 1;
  }
  if (commit.jsonFailed) {
    return fail(io, UNKNOWN, "malformed commit");
  }
  const parent = firstParent(commit.body);
  if (parent.kind === "malformed") {
    return fail(io, UNKNOWN, "malformed commit");
  }
  if (parent.kind !== "ok" || parent.sha !== before) {
    return fail(io, NONCOMPLIANT, "before sha is not the first parent");
  }
  return 0;
}

module.exports = { main, UNKNOWN, NONCOMPLIANT };

if (require.main === module) {
  main()
    .then((code) => {
      process.exitCode = code;
    })
    .catch((err) => {
      const message = err && err.message ? err.message : String(err);
      console.error(message);
      process.exitCode = 1;
    });
}
