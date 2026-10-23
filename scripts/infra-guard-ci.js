"use strict";
// Rule 13 CI check: no infrastructure information (local paths, private IPs, internal
// hosts, Apple signing identity / Team ID) in PR diffs, PR bodies, pushes or comments.
// Generic patterns only. Findings print "label:line: TYPE", never the matched value.

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");

const PATTERNS = [
  ["HOME_PATH", /\/Users\/[^/<\s]+/],
  ["HOME_PATH", /\/home\/[^/<\s]+/],
  ["PRIVATE_IP", /(?<![\d.])10\.\d{1,3}\.\d{1,3}\.\d{1,3}(?![\d.]*\d)/],
  ["PRIVATE_IP", /(?<![\d.])172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}(?![\d.]*\d)/],
  ["PRIVATE_IP", /(?<![\d.])192\.168\.\d{1,3}\.\d{1,3}(?![\d.]*\d)/],
  ["INTERNAL_HOST", /(?<![\w.-])[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.local(?![\w.-])/i],
  ["APPLE_SIGNING_IDENTITY", /Developer ID Applicatio[n]:/],
  ["APPLE_TEAM_ID", /\b(?:DEVELOPMENT_TEAM|TeamIdentifier|team[_ -]?id)\b["']?\s*[:=]\s*["']?[A-Z0-9]{10}\b/i],
  ["APPLE_TEAM_ID", /\((?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10}\)\s*$/],
];

function scanText(label, text) {
  const findings = [];
  String(text || "").split(/\r?\n/).forEach((line, i) => {
    const seen = new Set();
    for (const [type, re] of PATTERNS) {
      if (!seen.has(type) && re.test(line)) { seen.add(type); findings.push(`${label}:${i + 1}: ${type}`); }
    }
  });
  return findings;
}

// Only added lines of a unified diff count; line numbers are those of the new file.
function scanDiff(diff) {
  const findings = [];
  let file = "(diff)"; let n = 0;
  for (const line of String(diff || "").split("\n")) {
    let m;
    if ((m = /^\+\+\+ (?:b\/)?(.*)$/.exec(line))) { file = m[1]; continue; }
    if (line.startsWith("--- ")) continue;
    if ((m = /^@@ -\S+ \+(\d+)/.exec(line))) { n = Number(m[1]); continue; }
    if (line.startsWith("+")) {
      for (const f of scanText(file, line.slice(1))) findings.push(f.replace(/:1: /, `:${n}: `));
      n++;
    } else if (line.startsWith(" ")) n++;
  }
  return findings;
}

function gitDiff(base, head) {
  if (!base || /^0+$/.test(base)) return execFileSync("git", ["show", "--format=", "--no-color", "-U0", head], { encoding: "utf8", maxBuffer: 1 << 28 });
  return execFileSync("git", ["diff", "--no-color", "-U0", `${base}...${head}`], { encoding: "utf8", maxBuffer: 1 << 28 });
}

function scanEvent(name, event, diffFn = gitDiff) {
  const out = [];
  if (name === "pull_request" || name === "pull_request_target") {
    const pr = event.pull_request || {};
    out.push(...scanText("(pr title)", pr.title), ...scanText("(pr body)", pr.body));
    out.push(...scanDiff(diffFn(pr.base && pr.base.sha, pr.head && pr.head.sha)));
  } else if (name === "push") {
    for (const c of event.commits || []) out.push(...scanText(`(commit ${String(c.id).slice(0, 12)})`, c.message));
    out.push(...scanDiff(diffFn(event.before, event.after)));
  } else if (name === "issue_comment") {
    out.push(...scanText("(comment)", event.comment && event.comment.body));
    if (event.issue && event.issue.pull_request) out.push(...scanText("(pr body)", event.issue.body));
  }
  return out;
}

function main(argv = process.argv.slice(2), env = process.env) {
  let findings;
  if (argv[0] === "--diff") findings = scanDiff(fs.readFileSync(argv[1] || 0, "utf8"));
  else if (argv[0] === "--text") findings = scanText(argv[1] || "(stdin)", fs.readFileSync(argv[2] || 0, "utf8"));
  else findings = scanEvent(env.GITHUB_EVENT_NAME, JSON.parse(fs.readFileSync(env.GITHUB_EVENT_PATH, "utf8")));
  for (const f of findings) console.log(f);
  if (findings.length) {
    console.error("infra-guard: infrastructure information found (rule 13). Redact paths as ~ or <HOME>, hosts as <HOST>, IPs as <IP>.");
    return 1;
  }
  console.log("infra-guard: clean");
  return 0;
}

module.exports = { PATTERNS, scanText, scanDiff, scanEvent, main };
if (require.main === module) process.exitCode = main();
