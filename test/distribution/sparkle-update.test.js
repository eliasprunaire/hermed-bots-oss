"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");

// Flat key/value pairs of the app's Info.plist: raw value tokens such as <true/> or <string>x</string>
function plistEntries(file) {
  const text = fs.readFileSync(file, "utf8");
  const entries = {};
  for (const [, key, value] of text.matchAll(/<key>([^<]+)<\/key>\s*(<true\/>|<false\/>|<string>[^<]*<\/string>)/g)) entries[key] = value;
  return entries;
}

test("the app bundle carries the Sparkle feed, the public key and the signed-feed switches", () => {
  const plist = plistEntries("Config/Info.plist");
  // The release script fills these two build settings at archive time
  assert.equal(plist.SUFeedURL, "<string>$(SPARKLE_FEED_URL)</string>");
  assert.equal(plist.SUPublicEDKey, "<string>$(SPARKLE_PUBLIC_KEY)</string>");
  for (const key of ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableAutomaticChecks"]) {
    assert.equal(plist[key], "<true/>", key);
  }
});

const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const PROOF = "scripts/sparkle-update-proof.sh";

test("the update proof is valid shell and never expands the production signing key", () => {
  const syntax = spawnSync("bash", ["-n", PROOF], { encoding: "utf8" });
  assert.equal(syntax.status, 0, syntax.stderr);
  const source = fs.readFileSync(PROOF, "utf8");
  // The proof signs with a key pair created for the run; the repository secret must not even reach a child process
  assert.ok(!/\$\{?SPARKLE_PRIVATE_KEY/.test(source));
  assert.match(source, /^unset SPARKLE_PRIVATE_KEY$/m);
  assert.match(source, /^set \+x$/m);
});

test("the update proof refuses a machine that is not macOS and an unknown mode", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hermed-proof-"));
  try {
    fs.writeFileSync(path.join(root, "uname"), "#!/bin/sh\necho Linux\n", { mode: 0o755 });
    const env = { PATH: `${root}:${process.env.PATH}` };
    const linux = spawnSync("bash", [PROOF, "prepare"], { encoding: "utf8", env });
    assert.equal(linux.status, 2);
    assert.match(linux.stderr, /needs macOS/);
    const mode = spawnSync("bash", [PROOF, "publish"], { encoding: "utf8", env });
    assert.equal(mode.status, 2);
    assert.match(mode.stderr, /Usage: sparkle-update-proof\.sh \[prepare\|run\|published\]/);
    const published = spawnSync("bash", [PROOF, "published"], { encoding: "utf8", env });
    assert.equal(published.status, 2);
    assert.match(published.stderr, /needs macOS/);
    assert.doesNotMatch(published.stderr, /Usage/);
    const def = spawnSync("bash", [PROOF], { encoding: "utf8", env });
    assert.equal(def.status, 2);
    assert.match(def.stderr, /needs macOS/);
    assert.doesNotMatch(def.stderr, /published feed|SHA256SUMS|No HTTPS/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("published archive downloads follow GitHub redirects and fail on HTTP errors", () => {
  const source = fs.readFileSync(PROOF, "utf8").replace(/\\\n/g, " ");
  const downloads = [...source.matchAll(/\bcurl\b[^;\n]+releases\/download[^;\n]+/g)].map((match) => match[0]);
  assert.equal(downloads.length, 2);
  for (const call of downloads) {
    assert.match(call, /(?:^|\s)--location(?:\s|$)/);
    assert.match(call, /(?:^|\s)--fail(?:\s|$)/);
  }
});

test("published mode refuses when github.com is not reachable over HTTPS", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hermed-proof-pub-"));
  try {
    fs.writeFileSync(path.join(root, "uname"), "#!/bin/sh\necho Darwin\n", { mode: 0o755 });
    fs.writeFileSync(path.join(root, "curl"), "#!/bin/sh\nexit 7\n", { mode: 0o755 });
    const env = { PATH: `${root}:${process.env.PATH}` };
    const res = spawnSync("bash", [PROOF, "published"], { encoding: "utf8", env });
    assert.equal(res.status, 3);
    assert.match(res.stderr, /No HTTPS connection to github\.com/);
    assert.doesNotMatch(`${res.stdout}\n${res.stderr}`, /\/Users\/|\/home\/[^/\s]+/);
    assert.doesNotMatch(`${res.stdout}\n${res.stderr}`, /Usage/);
    assert.doesNotMatch(res.stdout, /SPARKLE-PROOF[^-]/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
