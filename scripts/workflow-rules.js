"use strict";

module.exports = Object.freeze([
  Object.freeze({
    rule: "Frozen versions and approved distribution configuration",
    script: "scripts/distribution.js",
    test: "test/distribution/release.test.js",
    job: "preflight",
  }),
  Object.freeze({
    rule: "No Cursor attribution, no Co-authored-by, no Open in Cursor footer",
    script: "scripts/check-pr-attribution.js",
    test: "test/check-pr-attribution.test.js",
    job: "pr-attribution",
  }),
  Object.freeze({
    rule: "Marked PASS or PASS+NOTES, posted by an allowlisted verifier, on the head SHA or a same-PR SHA with identical git patch-ids (--stable and --verbatim) and an exact replay tree against the PR base",
    script: "scripts/verdict-gate.js",
    test: "test/verdict-gate.test.js",
    job: "record-verdict",
  }),
  Object.freeze({
    rule: "Direct push to main",
    script: "scripts/check-main-push.js",
    test: "test/check-main-push.test.js",
    job: "require-merged-pull",
  }),
  Object.freeze({
    rule: "Program plans pass check-plan.mjs",
    script: "scripts/check-plans.js",
    test: "test/check-plans.test.js",
    job: "check-plans",
  }),
  Object.freeze({
    rule: "No change to .claude/, .codex/ or .mcp.json in a PR, and no change to gate files without an app-pilote-verifier[bot] gate-change-approved label and PASS on the current head SHA",
    script: "scripts/check-protected-paths.js",
    test: "test/check-protected-paths.test.js",
    job: "protected-agent-config",
  }),
  Object.freeze({
    rule: "No infrastructure information in diffs, PR bodies, pushes or comments",
    script: "scripts/infra-guard-ci.js",
    test: "test/infra-guard-ci.test.js",
    job: "scan",
  }),
  Object.freeze({
    rule: "One verifier per head SHA and one executor per PR",
    script: "scripts/check-anti-parallel.js",
    test: "test/check-anti-parallel.test.js",
    job: "anti-parallel",
  }),
]);
