"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { versionFromTag, releaseReadiness, renderCask } = require("../../scripts/distribution.js");

const ready = {
  APPLE_TEAM_ID: "test", DEVELOPER_ID_P12: "test", DEVELOPER_ID_P12_PASSWORD: "test",
  ASC_KEY_ID: "test", ASC_ISSUER_ID: "test", ASC_KEY_P8: "test",
  SPARKLE_PRIVATE_KEY: "test", SPARKLE_PUBLIC_KEY: Buffer.alloc(32, 1).toString("base64"),
  DISTRIBUTION_TOKEN: "test", DISTRIBUTION_REPOSITORY: "example/homebrew-hermed-bots",
  DISTRIBUTION_APPROVED: "true",
};

test("only final tags that fit Apple's bundle version become releases", () => {
  assert.equal(versionFromTag("v1.2.3"), "1.2.3");
  assert.equal(versionFromTag("v0.1.0"), "0.1.0");
  for (const tag of ["1.2.3", "v01.2.3", "v1.2.3-rc1", "v1.2.3\n", "v1.100.0", "v10000.0.0", "v1.2.$(id)"]) {
    assert.throws(() => versionFromTag(tag));
  }
});

test("missing credentials skip publication without exposing values", () => {
  const result = releaseReadiness({ APPLE_TEAM_ID: "sensitive-value" });
  assert.equal(result.ready, false);
  assert.ok(result.missing.includes("ASC_KEY_P8"));
  assert.ok(!JSON.stringify(result).includes("sensitive-value"));
  assert.equal(releaseReadiness(ready).ready, true);
});

test("public publishing requires explicit consent and valid public configuration", () => {
  for (const change of [
    { DISTRIBUTION_APPROVED: "false" }, { DISTRIBUTION_TOKEN: "" },
    { DISTRIBUTION_REPOSITORY: "example/repo\ninjection" },
    { DISTRIBUTION_REPOSITORY: "eliasprunaire/hermed-bots" },
    { SPARKLE_PUBLIC_KEY: "invalid" }, { SPARKLE_PUBLIC_KEY: ready.SPARKLE_PUBLIC_KEY + "\n" },
    { DISTRIBUTION_REPOSITORY: "Eliasprunaire/Hermed-bots" },
    { DISTRIBUTION_REPOSITORY: "eliasprunaire/hermed-bots-oss" },
    { DISTRIBUTION_REPOSITORY: "EliasPrunaire/Hermed-Bots-OSS" },
  ]) assert.equal(releaseReadiness({ ...ready, ...change }).ready, false);
});

test("cask pins the notarized archive hash and delegates updates to Sparkle", () => {
  const cask = renderCask("v1.2.3", "a".repeat(64), ready.DISTRIBUTION_REPOSITORY);
  assert.ok(cask.includes('version "1.2.3"'));
  assert.ok(cask.includes('sha256 "' + "a".repeat(64) + '"'));
  assert.ok(cask.includes('releases/download/v#{version}/HermedBots-#{version}.zip'));
  assert.ok(cask.includes("auto_updates true"));
  assert.ok(cask.includes('app "HermedBots.app"'));
  assert.throws(() => renderCask("v1.2.3", "bad", ready.DISTRIBUTION_REPOSITORY));
  assert.throws(() => renderCask("v1.2.3", "a".repeat(64), 'example/ruby"injection'));
});

test("the Homebrew tap is the owner's homebrew-tap repository", () => {
  const { tapRepository } = require("../../scripts/distribution.js");
  assert.equal(tapRepository("eliasprunaire/hermed-bots-releases"), "eliasprunaire/homebrew-tap");
  assert.throws(() => tapRepository("not a repository"));
});

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

test("missing keys skip signing on the real CLI", () => {
  const env = { PATH: process.env.PATH };
  const run = spawnSync("bash", ["scripts/release-macos.sh", "v0.1.0"], { encoding: "utf8", env });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /Distribution skipped/);
});

test("signing refuses a configured non-CI host", () => {
  const run = spawnSync("bash", ["scripts/release-macos.sh", "v0.1.0"], {
    encoding: "utf8", env: { PATH: process.env.PATH, ...ready },
  });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /ephemeral GitHub macOS runner/);
});

test("an incomplete configuration fails a rehearsal instead of passing silently", () => {
  const env = { PATH: process.env.PATH, REHEARSAL: "true" };
  const preflight = spawnSync(process.execPath, ["scripts/distribution.js", "preflight"], { encoding: "utf8", env });
  assert.equal(preflight.status, 1);
  assert.match(preflight.stdout, /Distribution skipped/);
  const build = spawnSync("bash", ["scripts/release-macos.sh", "v0.1.0"], { encoding: "utf8", env });
  assert.equal(build.status, 1);
  assert.match(build.stdout, /Distribution skipped/);
  const publication = spawnSync(process.execPath, ["scripts/distribution.js", "preflight"], { encoding: "utf8", env: { PATH: process.env.PATH, REHEARSAL: "false" } });
  assert.equal(publication.status, 0);
});

test("the rehearsal proof names build, signature, notarization and stapling and fails when one did not run", () => {
  const { rehearsalProof } = require("../../scripts/distribution.js");
  const full = rehearsalProof("build\nsignature\nnotarization\nstapling\n", "42");
  assert.equal(full.ok, true);
  assert.equal(full.text, "Rehearsal run 42\nbuild: pass\nsignature: pass\nnotarization: pass\nstapling: pass\n");
  const partial = rehearsalProof("build\nsignature\n", "42");
  assert.equal(partial.ok, false);
  assert.match(partial.text, /notarization: fail\nstapling: fail/);
  assert.equal(rehearsalProof("", "42").ok, false);
});

// Runs the whole release script against stub tools; `failure` names the stage whose stub fails
function release(failure, check) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hermed-release-"));
  try {
    fs.mkdirSync(path.join(root, "scripts"));
    for (const file of ["release-macos.sh", "distribution.js"]) {
      fs.copyFileSync(path.resolve("scripts", file), path.join(root, "scripts", file));
    }
    const bin = path.join(root, "bin");
    fs.mkdirSync(bin);
    const stub = `#!/bin/bash
set -eu
name=$(basename "$0")
echo "$name $*" >> "$TRACE"
case "$name" in
  xcodebuild)
    case "$1" in
      archive)
        mkdir -p .audit/distribution/packages/artifacts/sparkle/Sparkle/bin
        cp "$STUB" .audit/distribution/packages/artifacts/sparkle/Sparkle/bin/generate_appcast
        cp "$STUB" .audit/distribution/packages/artifacts/sparkle/Sparkle/bin/sign_update ;;
      -exportArchive) mkdir -p .audit/distribution/export/HermedBots.app ;;
    esac ;;
  xcrun)
    if [ "$1" = notarytool ]; then
      if [ "$FAILURE" = notary ]; then echo '{"status":"Invalid"}'; else echo '{"status":"Accepted"}'; fi
    fi ;;
  spctl) [ "$FAILURE" != gatekeeper ]; echo accepted ;;
  ditto) touch "\${!#}" ;;
  generate_appcast) touch .audit/distribution/out/appcast.xml ;;
  sign_update) [ "$FAILURE" != verify ] ;;
  git) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
esac
`;
    const stubPath = path.join(bin, "stub");
    fs.writeFileSync(stubPath, stub, { mode: 0o755 });
    for (const name of ["security", "codesign", "xcodebuild", "xcrun", "spctl", "ditto", "git"]) fs.symlinkSync(stubPath, path.join(bin, name));
    const trace = path.join(root, "trace");
    const result = spawnSync("bash", ["scripts/release-macos.sh", "v1.2.3"], {
      cwd: root, encoding: "utf8",
      env: { ...process.env, ...ready, DEVELOPER_ID_P12: "dGVzdA==", PATH: `${bin}:${process.env.PATH}`,
        GITHUB_ACTIONS: "true", RUNNER_OS: "macOS", RUNNER_TEMP: root, TRACE: trace, STUB: stubPath, FAILURE: failure },
    });
    check({ root, result, calls: fs.readFileSync(trace, "utf8"), output: path.join(root, ".audit/distribution/out") });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

function assertStages({ root, result, calls }, stages, proofStatus) {
  assert.match(calls, /security delete-keychain/);
  assert.equal(fs.readdirSync(root).filter(name => name.startsWith("hermed-signing.")).length, 0);
  const file = path.join(root, ".audit/distribution/stages.txt");
  const proof = spawnSync(process.execPath, ["scripts/distribution.js", "proof", file], { cwd: root, encoding: "utf8" });
  assert.deepEqual(fs.readFileSync(file, "utf8").split("\n").filter(Boolean), stages);
  assert.equal(proof.status, proofStatus);
}

const ALL_STAGES = ["build", "signature", "notarization", "stapling"];

test("release signs and staples before archiving; notarization and Gatekeeper failures prevent a feed", () => {
  for (const failure of ["none", "notary", "gatekeeper"]) {
    release(failure, run => {
      const { result, calls, output } = run;
      if (failure === "none") {
        assert.equal(result.status, 0, result.stderr);
        assert.ok(fs.existsSync(path.join(output, "hermed-bots.rb")));
        assert.ok(calls.indexOf("stapler staple") < calls.indexOf("ditto -c -k --sequesterRsrc --keepParent", calls.indexOf("stapler staple")));
        assert.ok(calls.indexOf("spctl -a") < calls.indexOf("generate_appcast"));
        assert.match(calls, /sign_update --verify/);
        assert.ok(calls.indexOf("generate_appcast") < calls.indexOf("sign_update --verify"));
        assert.ok(calls.includes(`SPARKLE_FEED_URL=https://github.com/${ready.DISTRIBUTION_REPOSITORY}/releases/latest/download/appcast.xml`));
        assert.ok(calls.includes(`SPARKLE_PUBLIC_KEY=${ready.SPARKLE_PUBLIC_KEY}`));
      } else {
        assert.notEqual(result.status, 0);
        assert.ok(!fs.existsSync(path.join(output, "appcast.xml")));
        if (failure === "notary") assert.ok(!calls.includes("stapler staple"));
      }
      assertStages(run, failure === "notary" ? ["build", "signature"] : ALL_STAGES, failure === "notary" ? 1 : 0);
    });
  }
});

test("a failed feed signature verification stops the release before the cask or the checksums exist", () => {
  release("verify", run => {
    const { result, calls, output } = run;
    assert.notEqual(result.status, 0);
    assert.match(calls, /sign_update --verify/);
    assert.ok(!fs.existsSync(path.join(output, "hermed-bots.rb")));
    assert.ok(!fs.existsSync(path.join(output, "SHA256SUMS")));
    assert.ok(!fs.existsSync(path.join(output, "commit.txt")));
    assert.ok(!calls.includes("git rev-parse"));
    assertStages(run, ALL_STAGES, 0);
  });
});

test("a retry may reuse a version but publication cannot move backwards", () => {
  const { assertReleaseOrder } = require("../../scripts/distribution.js");
  assert.doesNotThrow(() => assertReleaseOrder("v1.2.3", undefined));
  assert.doesNotThrow(() => assertReleaseOrder("v1.2.3", "v1.2.3"));
  assert.doesNotThrow(() => assertReleaseOrder("v1.10.0", "v1.9.0"));
  assert.throws(() => assertReleaseOrder("v1.2.3", "v1.2.4"));
  assert.throws(() => assertReleaseOrder("v1.2.3", "untrusted"));
});

test("publication only creates a release after a confirmed absence and preserves immutable assets", () => {
  for (const state of ["absent", "forbidden", "published", "changed"]) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "hermed-publish-"));
    try {
      fs.mkdirSync(path.join(root, "scripts"));
      for (const file of ["publish-distribution.sh", "distribution.js"]) fs.copyFileSync(path.resolve("scripts", file), path.join(root, "scripts", file));
      const output = path.join(root, ".audit/distribution/out");
      fs.mkdirSync(output, { recursive: true });
      fs.writeFileSync(path.join(output, "hermed-bots.rb"), "cask body\n");
      const checksum = require("node:crypto").createHash("sha256").update("cask body\n").digest("hex");
      fs.writeFileSync(path.join(output, "SHA256SUMS"), `${checksum}  hermed-bots.rb\n`);
      const bin = path.join(root, "bin");
      fs.mkdirSync(bin);
      const trace = path.join(root, "trace");
      fs.writeFileSync(path.join(bin, "git"), "#!/bin/sh\necho aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", { mode: 0o755 });
      fs.writeFileSync(path.join(bin, "gh"), `#!/bin/bash
set -eu
echo "$*" >> "$TRACE"
case "$*" in
  "api repos/"*" --jq .visibility") echo public ;;
  "release view"*)
    if [ "$STATE" = forbidden ]; then echo 'HTTP 403' >&2; exit 1; fi
    if [ "$STATE" = absent ]; then echo 'release not found' >&2; exit 1; fi
    case "$*" in *tagName*) echo '{"tagName":"v1.2.3"}' ;; *) echo '{"isDraft":false}' ;; esac ;;
  "release download"*)
    if [ "$STATE" = changed ]; then echo changed > .audit/distribution/published/SHA256SUMS
    else cp .audit/distribution/out/SHA256SUMS .audit/distribution/published/SHA256SUMS; fi ;;
  "api repos/"*"/contents/"*) echo 'HTTP 404' >&2; exit 1 ;;
esac
`, { mode: 0o755 });
      const result = spawnSync("bash", ["scripts/publish-distribution.sh", "v1.2.3"], {
        cwd: root, encoding: "utf8", env: { ...process.env, PATH: `${bin}:${process.env.PATH}`,
          GH_TOKEN: "test", DISTRIBUTION_APPROVED: "true", DISTRIBUTION_REPOSITORY: ready.DISTRIBUTION_REPOSITORY, TRACE: trace, STATE: state },
      });
      const calls = fs.readFileSync(trace, "utf8");
      if (state === "forbidden" || state === "changed") {
        assert.notEqual(result.status, 0);
        assert.ok(!calls.includes("release create"));
        assert.ok(!calls.includes("--method PUT"));
      } else {
        assert.equal(result.status, 0, result.stderr);
        assert.ok(calls.includes("--method PUT repos/example/homebrew-tap/contents/Casks/hermed-bots.rb"));
        if (state === "absent") {
          assert.ok(calls.indexOf("release upload") < calls.indexOf("release edit"));
          assert.ok(calls.indexOf("release edit") < calls.indexOf("--method PUT"));
        } else {
          assert.ok(!calls.includes("release upload"));
          assert.ok(!calls.includes("release edit"));
        }
      }
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  }
});

test("publication refuses missing consent and corrupted local artifacts before contacting GitHub", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hermed-publish-gate-"));
  try {
    fs.mkdirSync(path.join(root, "scripts"));
    for (const file of ["publish-distribution.sh", "distribution.js"]) fs.copyFileSync(path.resolve("scripts", file), path.join(root, "scripts", file));
    const output = path.join(root, ".audit/distribution/out");
    fs.mkdirSync(output, { recursive: true });
    fs.writeFileSync(path.join(output, "SHA256SUMS"), "0".repeat(64) + "  hermed-bots.rb\n");
    fs.writeFileSync(path.join(output, "hermed-bots.rb"), "tampered");
    const bin = path.join(root, "bin");
    fs.mkdirSync(bin);
    fs.writeFileSync(path.join(bin, "gh"), '#!/bin/sh\ntouch "$CONTACTED"\nexit 99\n', { mode: 0o755 });
    for (const consent of ["false", "true"]) {
      const run = spawnSync("bash", ["scripts/publish-distribution.sh", "v1.2.3"], {
        cwd: root, encoding: "utf8", env: { ...process.env, PATH: `${bin}:${process.env.PATH}`,
          GH_TOKEN: "test", DISTRIBUTION_APPROVED: consent, DISTRIBUTION_REPOSITORY: ready.DISTRIBUTION_REPOSITORY, CONTACTED: path.join(root, "contacted") },
      });
      assert.notEqual(run.status, 0);
      assert.ok(!fs.existsSync(path.join(root, "contacted")));
      assert.match(run.stdout + run.stderr, consent === "false" ? /DISTRIBUTION_APPROVED/ : /FAILED/);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the open-source source repository is never a valid tap source", () => {
  const { tapRepository } = require("../../scripts/distribution.js");
  assert.throws(() => tapRepository("eliasprunaire/hermed-bots-oss"), /Invalid distribution repository/);
  assert.equal(tapRepository("eliasprunaire/hermed-bots-releases"), "eliasprunaire/homebrew-tap");
});
