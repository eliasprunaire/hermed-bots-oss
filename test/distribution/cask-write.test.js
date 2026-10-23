"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");

const CASK = "cask body\n";
const REMOTE_SHA = "abc123remote";
const PUT = "--method PUT repos/example/homebrew-tap/contents/Casks/hermed-bots.rb";

// Runs the whole publish script against a stub gh whose cask GET answers per case
function publish(remote) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hermed-cask-"));
  try {
    fs.mkdirSync(path.join(root, "scripts"));
    for (const file of ["publish-distribution.sh", "distribution.js"]) fs.copyFileSync(path.resolve("scripts", file), path.join(root, "scripts", file));
    const output = path.join(root, ".audit/distribution/out");
    fs.mkdirSync(output, { recursive: true });
    fs.writeFileSync(path.join(output, "hermed-bots.rb"), CASK);
    const checksum = crypto.createHash("sha256").update(CASK).digest("hex");
    fs.writeFileSync(path.join(output, "SHA256SUMS"), `${checksum}  hermed-bots.rb\n`);
    const bin = path.join(root, "bin");
    fs.mkdirSync(bin);
    const trace = path.join(root, "trace");
    const requests = path.join(root, "requests");
    fs.mkdirSync(requests);
    // The release is already published, so only the cask write section changes state
    fs.writeFileSync(path.join(bin, "gh"), `#!/bin/bash
set -eu
echo "$*" >> "$TRACE"
case "$*" in
  "api repos/"*" --jq .visibility") echo public ;;
  "release view"*)
    case "$*" in *tagName*) echo '{"tagName":"v1.2.3"}' ;; *) echo '{"isDraft":false}' ;; esac ;;
  "release download"*) cp .audit/distribution/out/SHA256SUMS .audit/distribution/published/SHA256SUMS ;;
  "api --method PUT"*)
    cp "$6" "$REQUESTS/put-$(ls "$REQUESTS" | wc -l | tr -d ' ').json" ;;
  "api repos/"*"/contents/"*)
    case "$REMOTE" in
      404) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      error) echo 'gh: Forbidden (HTTP 403)' >&2; exit 1 ;;
      *) echo "$REMOTE_JSON" ;;
    esac ;;
esac
`, { mode: 0o755 });
    const content = remote.content === undefined ? "" : Buffer.from(remote.content).toString("base64").replace(/(.{60})/g, "$1\n");
    const result = spawnSync("bash", ["scripts/publish-distribution.sh", "v1.2.3"], {
      cwd: root, encoding: "utf8", env: { ...process.env, PATH: `${bin}:${process.env.PATH}`,
        GH_TOKEN: "test", DISTRIBUTION_APPROVED: "true", DISTRIBUTION_REPOSITORY: "example/hermed-bots-releases",
        TRACE: trace, REQUESTS: requests, REMOTE: remote.kind, REMOTE_JSON: JSON.stringify({ sha: REMOTE_SHA, content }) },
    });
    const puts = fs.readFileSync(trace, "utf8").split("\n").filter(line => line.includes(PUT));
    const bodies = fs.readdirSync(requests).map(name => JSON.parse(fs.readFileSync(path.join(requests, name), "utf8")));
    return { result, puts, bodies };
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("cask write: a 404 from the tap creates the file with one PUT and no sha", () => {
  const { result, puts, bodies } = publish({ kind: "404" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(puts.length, 1);
  assert.equal(bodies.length, 1);
  assert.ok(!("sha" in bodies[0]));
  assert.equal(Buffer.from(bodies[0].content, "base64").toString(), CASK);
  assert.match(bodies[0].message, /^chore\(cask\): release Hermed Bots 1\.2\.3$/);
});

test("cask write: identical remote content sends no PUT and exits 0", () => {
  const { result, puts } = publish({ kind: "ok", content: CASK });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Homebrew cask already current/);
  assert.equal(puts.length, 0);
});

test("cask write: different remote content sends one PUT that carries the remote sha", () => {
  const { result, puts, bodies } = publish({ kind: "ok", content: "old cask\n" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(puts.length, 1);
  assert.equal(bodies[0].sha, REMOTE_SHA);
  assert.equal(Buffer.from(bodies[0].content, "base64").toString(), CASK);
});

test("cask write: a remote error other than 404 stops with a non-zero exit and no PUT", () => {
  const { result, puts } = publish({ kind: "error" });
  assert.notEqual(result.status, 0);
  assert.equal(puts.length, 0);
});
