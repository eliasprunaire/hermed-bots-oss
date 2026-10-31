"use strict";

const { spawnSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const { MARKER, verdictLines, plainMarker } = require("./verdict-prose.js");

const STATUS_CONTEXT = "verdict-gate";
const DESCRIPTION_MAX = 140;
const UNREADABLE_DESCRIPTION = "could not read PR comments";
const HEX_SHA = /^[0-9a-fA-F]{40}$/;
const HEX_PATCH = /^[0-9a-f]{40}$/;
const GRAPHQL_URL = "https://api.github.com/graphql";
const FORCE_PUSH_QUERY = `query($owner:String!,$name:String!,$number:Int!,$commitsCursor:String,$timelineCursor:String){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      commits(first:100,after:$commitsCursor){
        pageInfo{hasNextPage endCursor}
        nodes{commit{oid}}
      }
      timelineItems(first:100,after:$timelineCursor,itemTypes:[HEAD_REF_FORCE_PUSHED_EVENT]){
        pageInfo{hasNextPage endCursor}
        nodes{
          ... on HeadRefForcePushedEvent{
            beforeCommit{oid}
            afterCommit{oid}
          }
        }
      }
    }
  }
}`;
const VERIFIERS = Object.freeze([
  Object.freeze({ login: "app-pilote-verifier[bot]", type: "Bot" }),
]);
const SIGNALERS = Object.freeze([
  Object.freeze({ login: "cursor[bot]", type: "Bot" }),
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

function addHexSha(set, value) {
  if (typeof value === "string" && HEX_SHA.test(value)) {
    set.add(value.toLowerCase());
  }
}

function harvestShas(raw, set) {
  if (raw == null || typeof raw !== "object") {
    return;
  }
  addHexSha(set, raw.sha);
  addHexSha(set, raw.oid);
  addHexSha(set, raw.commit_id);
  if (typeof raw.before === "string") {
    addHexSha(set, raw.before);
  }
  if (typeof raw.after === "string") {
    addHexSha(set, raw.after);
  }
  if (raw.commit != null && typeof raw.commit === "object") {
    harvestShas(raw.commit, set);
  }
  if (raw.beforeCommit != null && typeof raw.beforeCommit === "object") {
    harvestShas(raw.beforeCommit, set);
  }
  if (raw.afterCommit != null && typeof raw.afterCommit === "object") {
    harvestShas(raw.afterCommit, set);
  }
}

// referenced, closed and merged events also carry a commit_id, from any branch or repo
const MEMBERSHIP_EVENTS = new Set(["committed", "head_ref_force_pushed"]);

function harvestTimelineShas(raw, set) {
  if (raw != null && typeof raw === "object" && MEMBERSHIP_EVENTS.has(raw.event)) {
    harvestShas(raw, set);
  }
}

function shaSet(value) {
  const out = new Set();
  if (value == null) {
    return out;
  }
  const list = value instanceof Set || Array.isArray(value) ? value : [];
  for (const item of list) {
    addHexSha(out, item);
  }
  return out;
}

function patchMap(value) {
  const out = Object.create(null);
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    return out;
  }
  for (const [key, patchId] of Object.entries(value)) {
    if (!HEX_SHA.test(key)) {
      continue;
    }
    if (patchId === "") {
      out[key.toLowerCase()] = "";
      continue;
    }
    if (typeof patchId === "string" && HEX_PATCH.test(patchId.toLowerCase())) {
      out[key.toLowerCase()] = patchId.toLowerCase();
    }
  }
  return out;
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

function isListed(comment, list) {
  if (comment == null || comment.user == null) {
    return false;
  }
  const { login, type } = comment.user;
  return list.some((entry) => entry.login === login && entry.type === type);
}

function isVerifier(comment, verifiers) {
  return isListed(comment, verifiers);
}

function readableComment(comment) {
  return (
    comment != null &&
    typeof comment.id === "string" &&
    /^[0-9]+$/.test(comment.id) &&
    typeof comment.createdAtMs === "number" &&
    Number.isFinite(comment.createdAtMs) &&
    typeof comment.body === "string"
  );
}

function signalVerdict(comments, headSha, onPull, ids) {
  let newest = null;
  let verdict = null;
  for (const comment of comments) {
    if (!isListed(comment, SIGNALERS) || !readableComment(comment)) {
      continue;
    }
    if (!plainMarker(comment.body)) {
      continue;
    }
    const match = verdictLines(comment.body).find(
      (line) => qualifies(line.sha, headSha, onPull, ids) != null,
    );
    if (match == null) {
      continue;
    }
    if (newest == null || isNewer(comment, newest)) {
      newest = comment;
      verdict = match.verdict;
    }
  }
  return verdict;
}

function attachSignal(decision, signal) {
  if (signal == null || decision.kind !== "fail" || decision.reason.code !== "none") {
    return decision;
  }
  const next = `${decision.description}; cursor[bot] ${signal}`;
  if (next.length > DESCRIPTION_MAX) {
    return decision;
  }
  return { ...decision, description: next };
}

function foldLogin(value) {
  if (typeof value !== "string" || value === "") {
    return null;
  }
  return value.toLowerCase();
}

function headIdOf(value) {
  if (typeof value !== "string") {
    return null;
  }
  if (value === "") {
    return "";
  }
  const id = value.toLowerCase();
  return HEX_PATCH.test(id) ? id : null;
}

// a reused verdict needs three equal fingerprints: --stable ignores whitespace, --verbatim ignores
// hunk position, and only the replay tree proves the head holds exactly the cited changes
function qualifies(sha, headSha, onPull, ids) {
  if (sha === headSha) {
    return { via: "head", patchId: ids.headPatchId };
  }
  if (!onPull.has(sha)) {
    return null;
  }
  for (const id of [ids.headPatchId, ids.headExactId, ids.headReplayId]) {
    if (id == null || id === "") {
      return null;
    }
  }
  const patchId = ids.patches[sha];
  const exactId = ids.exacts[sha];
  const replayId = ids.replays[sha];
  if (
    typeof patchId !== "string" ||
    patchId === "" ||
    patchId !== ids.headPatchId ||
    typeof exactId !== "string" ||
    exactId === "" ||
    exactId !== ids.headExactId ||
    typeof replayId !== "string" ||
    replayId === "" ||
    replayId !== ids.headReplayId
  ) {
    return null;
  }
  return { via: "patch", patchId };
}

function mismatchDescription(
  verdict,
  citedSha,
  headSha,
  onPull,
  ids,
  onPullProvided,
) {
  if (onPullProvided && !onPull.has(citedSha) && citedSha !== headSha) {
    return render(`VERDICT ${verdict} @ ${citedSha} is not on this pull`);
  }
  if (
    ids.headPatchId === "" ||
    ids.patches[citedSha] === "" ||
    ids.headExactId === "" ||
    ids.exacts[citedSha] === ""
  ) {
    return render(`empty patch-id refused for ${citedSha}`);
  }
  return render(`VERDICT ${verdict} @ ${citedSha} does not match head ${headSha}`);
}

function passDescription(verdict, sha, via, patchId) {
  if (via === "patch" && typeof patchId === "string" && HEX_PATCH.test(patchId)) {
    return render(`VERDICT ${verdict} @ ${sha} pid ${patchId}`);
  }
  return render(`VERDICT ${verdict} @ ${sha}`);
}

function decide(input) {
  const headSha = requireHead(input.headSha);
  const verifiers = usableVerifiers(input.verifiers);
  const onPullProvided = Object.prototype.hasOwnProperty.call(input, "onPull");
  const onPull = shaSet(input.onPull);
  onPull.add(headSha);
  const ids = {
    patches: patchMap(input.patchIds),
    headPatchId: headIdOf(input.headPatchId),
    exacts: patchMap(input.exactIds),
    headExactId: headIdOf(input.headExactId),
    replays: patchMap(input.replayIds),
    headReplayId: headIdOf(input.headReplayId),
  };
  let seenLine = false;
  let seenMarker = false;
  let winner = null;
  let unmatched = null;

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
    const anyQualifies = lines.some(
      (line) => qualifies(line.sha, headSha, onPull, ids) != null,
    );
    const row = {
      id: comment.id,
      createdAtMs: comment.createdAtMs,
      lines,
      login: foldLogin(readLogin(comment.user)),
    };
    if (anyQualifies) {
      if (winner == null || isNewer(comment, winner)) {
        winner = row;
      }
    } else if (unmatched == null || isNewer(comment, unmatched)) {
      unmatched = row;
    }
  }

  if (winner == null) {
    if (unmatched != null) {
      const first = unmatched.lines[0];
      return {
        kind: "fail",
        reason: {
          code:
            onPullProvided && !onPull.has(first.sha)
              ? "not-on-pull"
              : "sha-mismatch",
          verdict: first.verdict,
          citedSha: first.sha,
          headSha,
          commentId: unmatched.id,
        },
        description: mismatchDescription(
          first.verdict,
          first.sha,
          headSha,
          onPull,
          ids,
          onPullProvided,
        ),
      };
    }
    let hint = "neither";
    if (seenLine) {
      hint = "line-without-marker";
    } else if (seenMarker) {
      hint = "marker-without-line";
    }
    return attachSignal(
      {
        kind: "fail",
        reason: { code: "none", headSha, hint },
        description: render(noneDescription(hint, headSha)),
      },
      signalVerdict(input.comments, headSha, onPull, ids),
    );
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

  const match = qualifies(first.sha, headSha, onPull, ids);
  if (match == null) {
    return {
      kind: "fail",
      reason: {
        code: "sha-mismatch",
        verdict: first.verdict,
        citedSha: first.sha,
        headSha,
        commentId: winner.id,
      },
        description: mismatchDescription(
        first.verdict,
        first.sha,
        headSha,
        onPull,
        ids,
        onPullProvided,
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
      description:
        match.via === "patch"
          ? passDescription("FAIL", first.sha, match.via, match.patchId)
          : render(`VERDICT FAIL @ ${headSha}`),
    };
  }

  return {
    kind: "pass",
    verdict: first.verdict,
    sha: first.sha,
    commentId: winner.id,
    description: passDescription(first.verdict, first.sha, match.via, match.patchId),
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

async function githubRequest(io, token, url, init = {}) {
  const headers = { ...apiHeaders(token), ...(init.headers || {}) };
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = await io.fetch(url, { ...init, headers });
      if (response && response.ok) {
        return response;
      }
    } catch {
      continue;
    }
  }
  throw new Error("request failed");
}

async function githubGet(io, token, url) {
  return githubRequest(io, token, url);
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

function citedOffHead(comments, verifiers, headSha) {
  const shas = new Set();
  for (const comment of comments) {
    if (!isVerifier(comment, verifiers)) {
      continue;
    }
    if (!plainMarker(comment.body)) {
      continue;
    }
    for (const line of verdictLines(comment.body)) {
      if (line.sha !== headSha) {
        shas.add(line.sha);
      }
    }
  }
  return shas;
}

function gitRun(io, args, input) {
  if (typeof io.run !== "function") {
    return { status: 1, stdout: "" };
  }
  const result = io.run(["git", ...args], input);
  if (result == null || typeof result !== "object") {
    return { status: 1, stdout: "" };
  }
  return {
    status: typeof result.status === "number" ? result.status : 1,
    stdout: typeof result.stdout === "string" ? result.stdout : "",
  };
}

function hasCommit(io, sha) {
  const result = gitRun(io, ["cat-file", "-t", sha]);
  return result.status === 0 && result.stdout.trim() === "commit";
}

function hasOrigin(io) {
  return gitRun(io, ["remote", "get-url", "origin"]).status === 0;
}

function fetchCommit(io, sha) {
  if (hasCommit(io, sha)) {
    return true;
  }
  if (!hasOrigin(io)) {
    return false;
  }
  // no --depth: a cut history leaves merge-base without a common ancestor
  // shortcut: a shallow clone whose base moved past the fork point still fails, the workflow uses fetch-depth 0
  gitRun(io, ["fetch", "--no-tags", "origin", sha]);
  return hasCommit(io, sha);
}

function isAncestor(io, maybeAncestor, headSha) {
  if (!hasCommit(io, maybeAncestor) || !hasCommit(io, headSha)) {
    return false;
  }
  return gitRun(io, ["merge-base", "--is-ancestor", maybeAncestor, headSha]).status === 0;
}

function diffPatchId(io, sha, baseSha) {
  if (!fetchCommit(io, sha) || !fetchCommit(io, baseSha)) {
    return { kind: "missing" };
  }
  const mergeBase = gitRun(io, ["merge-base", sha, baseSha]);
  if (mergeBase.status !== 0) {
    return { kind: "missing" };
  }
  const base = mergeBase.stdout.trim();
  if (!HEX_SHA.test(base)) {
    return { kind: "missing" };
  }
  const diff = gitRun(io, ["diff", "--no-ext-diff", "--binary", base, sha]);
  if (diff.status !== 0) {
    return { kind: "missing" };
  }
  if (diff.stdout === "") {
    return { kind: "empty" };
  }
  const patch = gitRun(io, ["patch-id", "--stable"], diff.stdout);
  const exact = gitRun(io, ["patch-id", "--verbatim"], diff.stdout);
  if (patch.status !== 0 || exact.status !== 0) {
    return { kind: "missing" };
  }
  const id = patch.stdout.trim().split(/\s+/)[0] || "";
  const exactId = exact.stdout.trim().split(/\s+/)[0] || "";
  if (!HEX_PATCH.test(id) || !HEX_PATCH.test(exactId)) {
    return { kind: "empty" };
  }
  return { kind: "ok", patchId: id, exactId, mergeBase: base };
}

async function loadHistoryShas(io, token, owner, repo, number) {
  const shas = new Set();
  try {
    const commitPages = await loadPages(
      io,
      token,
      `https://api.github.com/repos/${owner}/${repo}/pulls/${number}/commits?per_page=100`,
    );
    for (const page of commitPages) {
      for (const raw of page) {
        harvestShas(raw, shas);
      }
    }
  } catch {
    // fail closed: only SHAs gathered elsewhere count
  }
  try {
    const timelinePages = await loadPages(
      io,
      token,
      `https://api.github.com/repos/${owner}/${repo}/issues/${number}/timeline?per_page=100`,
    );
    for (const page of timelinePages) {
      for (const raw of page) {
        harvestTimelineShas(raw, shas);
      }
    }
  } catch {
    // fail closed
  }
  let commitsCursor = null;
  let timelineCursor = null;
  let commitsDone = false;
  let timelineDone = false;
  for (let page = 0; page < 20 && (!commitsDone || !timelineDone); page += 1) {
    let payload;
    try {
      const response = await githubRequest(io, token, GRAPHQL_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({
          query: FORCE_PUSH_QUERY,
          variables: {
            owner,
            name: repo,
            number,
            commitsCursor,
            timelineCursor,
          },
        }),
      });
      payload = await response.json();
    } catch {
      break;
    }
    const pull =
      payload && payload.data && payload.data.repository
        ? payload.data.repository.pullRequest
        : null;
    if (pull == null) {
      break;
    }
    if (!commitsDone) {
      const commits = pull.commits;
      if (commits && Array.isArray(commits.nodes)) {
        for (const node of commits.nodes) {
          harvestShas(node, shas);
        }
      }
      const info = commits && commits.pageInfo;
      if (info && info.hasNextPage === true && nonEmpty(info.endCursor)) {
        commitsCursor = info.endCursor;
      } else {
        commitsDone = true;
      }
    }
    if (!timelineDone) {
      const items = pull.timelineItems;
      if (items && Array.isArray(items.nodes)) {
        for (const node of items.nodes) {
          harvestShas(node, shas);
        }
      }
      const info = items && items.pageInfo;
      if (info && info.hasNextPage === true && nonEmpty(info.endCursor)) {
        timelineCursor = info.endCursor;
      } else {
        timelineDone = true;
      }
    }
  }
  return shas;
}

// tree git builds by replaying the cited diff (shaBase..sha) onto headBase; null on conflict or error
// shortcut: needs git 2.40+ (merge-tree --write-tree), an older git yields null and the verdict is refused
function replayTree(io, sha, shaBase, headBase) {
  const result = gitRun(io, [
    "merge-tree",
    "--write-tree",
    `--merge-base=${shaBase}`,
    headBase,
    sha,
  ]);
  if (result.status !== 0) {
    return null;
  }
  const tree = result.stdout.split("\n")[0].trim();
  return HEX_PATCH.test(tree) ? tree : null;
}

function treeOf(io, sha) {
  const result = gitRun(io, ["rev-parse", "--verify", `${sha}^{tree}`]);
  const tree = result.stdout.trim();
  return result.status === 0 && HEX_PATCH.test(tree) ? tree : null;
}

function patchIdentity(io, shas, headSha, baseSha) {
  const patchIds = Object.create(null);
  const exactIds = Object.create(null);
  const replayIds = Object.create(null);
  const head = diffPatchId(io, headSha, baseSha);
  let headPatchId = null;
  let headExactId = null;
  let headReplayId = null;
  if (head.kind === "empty") {
    headPatchId = "";
    headExactId = "";
    headReplayId = "";
  } else if (head.kind === "ok") {
    headPatchId = head.patchId;
    headExactId = head.exactId;
    headReplayId = treeOf(io, headSha);
  }
  for (const sha of shas) {
    if (sha === headSha) {
      continue;
    }
    const result = diffPatchId(io, sha, baseSha);
    if (result.kind === "empty") {
      patchIds[sha] = "";
      exactIds[sha] = "";
      replayIds[sha] = "";
    } else if (result.kind === "ok") {
      patchIds[sha] = result.patchId;
      exactIds[sha] = result.exactId;
      if (head.kind === "ok") {
        const tree = replayTree(io, sha, result.mergeBase, head.mergeBase);
        if (tree != null) {
          replayIds[sha] = tree;
        }
      }
    }
  }
  return {
    headPatchId,
    patchIds,
    headExactId,
    exactIds,
    headReplayId,
    replayIds,
  };
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
    const sha = pull && pull.head ? pull.head.sha : undefined;
    return {
      action: "ready",
      number: issue.number,
      sha,
      authorLogin: readLogin(pull && pull.user),
      baseSha: readBaseSha(pull),
    };
  }
  if (eventName === "pull_request" || eventName === "pull_request_target") {
    const pullRequest = payload.pull_request;
    const sha =
      pullRequest && pullRequest.head ? pullRequest.head.sha : undefined;
    const number = pullRequest ? pullRequest.number : undefined;
    return {
      action: "ready",
      number,
      sha,
      authorLogin: readLogin(pullRequest && pullRequest.user),
      baseSha: readBaseSha(pullRequest),
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

  const verifiers = usableVerifiers(io.verifiers);
  const offHead = citedOffHead(comments, verifiers, headSha);
  const onPull = new Set([headSha]);
  let headPatchId;
  let headExactId;
  let headReplayId;
  let patchIds = Object.create(null);
  let exactIds = Object.create(null);
  let replayIds = Object.create(null);
  if (offHead.size > 0 && head.baseSha != null) {
    const history = await loadHistoryShas(
      io,
      token,
      names.owner,
      names.repo,
      head.number,
    );
    fetchCommit(io, headSha);
    fetchCommit(io, head.baseSha);
    for (const sha of history) {
      if (sha === headSha) {
        continue;
      }
      if (!fetchCommit(io, sha)) {
        continue;
      }
      if (isAncestor(io, sha, head.baseSha)) {
        continue;
      }
      onPull.add(sha);
    }
    const identity = patchIdentity(io, onPull, headSha, head.baseSha);
    headPatchId = identity.headPatchId;
    patchIds = identity.patchIds;
    headExactId = identity.headExactId;
    exactIds = identity.exactIds;
    headReplayId = identity.headReplayId;
    replayIds = identity.replayIds;
  }

  const decision = decide({
    headSha,
    comments,
    authorLogin: head.authorLogin,
    verifiers: io.verifiers,
    onPull,
    headPatchId,
    patchIds,
    headExactId,
    exactIds,
    headReplayId,
    replayIds,
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
