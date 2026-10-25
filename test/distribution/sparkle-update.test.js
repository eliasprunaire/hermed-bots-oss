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

test("Release imposes the on-demand Sparkle policy before the updater starts", () => {
  const app = fs.readFileSync("HermedBots/App/HermedBotsApp.swift", "utf8");
  const driver = fs.readFileSync("HermedBots/Updates/SparkleUpdateDriver.swift", "utf8");
  assert.match(driver, /UpdatePolicy\.imposed\(on: stored\)/);
  assert.match(driver, /automaticallyChecksForUpdates = policy\.automaticallyChecks/);
  assert.match(driver, /automaticallyDownloadsUpdates = policy\.automaticallyDownloads/);
  const start = app.indexOf("SPUStandardUpdaterController(startingUpdater:");
  const slice = app.slice(start, start + 400);
  assert.match(slice, /startingUpdater: false/);
  assert.ok(slice.indexOf("driver.attach") < slice.indexOf("startUpdater()"));
});

test("the app bundle carries the Sparkle feed, the public key and the signed-feed switches", () => {
  const plist = plistEntries("Config/Info.plist");
  // The release script fills these two build settings at archive time
  assert.equal(plist.SUFeedURL, "<string>$(SPARKLE_FEED_URL)</string>");
  assert.equal(plist.SUPublicEDKey, "<string>$(SPARKLE_PUBLIC_KEY)</string>");
  for (const key of ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"]) {
    assert.equal(plist[key], "<true/>", key);
  }
  for (const key of ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate"]) {
    assert.equal(plist[key], "<false/>", key);
  }
});

const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const PROOF = "scripts/sparkle-update-proof.sh";

test("the archive refusal pass confirms Sparkle then waits for the zip and rejects the installer", () => {
  const source = fs.readFileSync(PROOF, "utf8");
  const pass = source.slice(source.indexOf("pass() {"));
  assert.match(pass, /if \[ "\$name" != feed-signature \]; then confirm_sparkle_install/);
  const archiveArm = pass.slice(pass.indexOf("wait_until 120 requested \"HermedBots-$n1.zip\""));
  assert.match(archiveArm, /if \[ "\$expect" = refuse \] && installer_up/);
  assert.ok(pass.indexOf("confirm_sparkle_install") < pass.indexOf("requested \"HermedBots-$n1.zip\""));
});

test("the live proof starts a user-driven Sparkle check before it waits for the feed", () => {
  const source = fs.readFileSync(PROOF, "utf8");
  assert.match(source, /request_user_check/);
  assert.match(source, /whose name contains "mises"/);
  const pass = source.slice(source.indexOf("pass() {"));
  assert.ok(pass.indexOf("request_user_check") < pass.indexOf("requested appcast.xml"));
  const published = source.slice(0, source.indexOf("if [ \"$mode\" = published ]"));
  assert.ok(published.includes("request_user_check"));
  assert.ok(published.indexOf("request_user_check") < published.lastIndexOf("sparkle_progress"));
});

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

function fakePlist(version) {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<plist version="1.0"><dict>',
    "<key>CFBundleShortVersionString</key>",
    `<string>${version}</string>`,
    "<key>CFBundleIdentifier</key>",
    "<string>com.hermedbots.HermedBots</string>",
    "</dict></plist>",
    "",
  ].join("\n");
}

function writeFakeApp(dir, version) {
  fs.mkdirSync(path.join(dir, "Contents"), { recursive: true });
  fs.writeFileSync(path.join(dir, "Contents", "Info.plist"), fakePlist(version));
  return dir;
}

function lsregisterDump(entries) {
  return entries
    .map(
      (entry) =>
        [
          "--------------------------------------------------------------------------------",
          "bundle  id:            1",
          `\tpath:          ${entry.path}`,
          `\tidentifier:    ${entry.id}`,
        ].join("\n"),
    )
    .join("\n");
}

function countCopies({ home, buildDir, target, mdfind, lsregister }) {
  const box = fs.mkdtempSync(path.join(os.tmpdir(), "sparkle-count-"));
  const mdFile = path.join(box, "mdfind.txt");
  const lsFile = path.join(box, "lsregister.txt");
  fs.writeFileSync(mdFile, mdfind || "");
  fs.writeFileSync(lsFile, lsregister || "");
  try {
    return spawnSync(
      "bash",
      ["-c", "SPARKLE_PROOF_SOURCE=1; . scripts/sparkle-update-proof.sh; count_hermedbots_copies"],
      {
        encoding: "utf8",
        cwd: path.join(__dirname, "../.."),
        env: {
          PATH: process.env.PATH,
          HOME: home,
          SPARKLE_PROOF_TARGET_VERSION: target,
          SPARKLE_PROOF_BUILD_DIR: buildDir || "",
          SPARKLE_PROOF_MDFIND_FILE: mdFile,
          SPARKLE_PROOF_LSREGISTER_FILE: lsFile,
        },
      },
    );
  } finally {
    fs.rmSync(box, { recursive: true, force: true });
  }
}

test("the proof line records single-copy and discovers the shipping identifier after relaunch", () => {
  const source = fs.readFileSync(PROOF, "utf8");
  assert.match(source, /mdfind "kMDItemCFBundleIdentifier == 'com\.hermedbots\.HermedBots'"/);
  assert.match(source, /lsregister -dump/);
  assert.match(source, /SPARKLE_PROOF_BUILD_DIR/);
  assert.match(source, /count_hermedbots_copies/);
  assert.match(
    source,
    /SPARKLE-PROOF-PUBLISHED from=\$\{from:-none\} to=\$\{to:-none\} feed=\$feed install=\$install installed-after-relaunch=\$installed_after codesign=\$codesign_verdict spctl=\$spctl_verdict single-copy \$single_copy/,
  );
  assert.match(
    source,
    /SPARKLE-PROOF N=\$n N1=\$n1 feed-signature=pass install=pass installed-after-relaunch=\$installed_after_update altered-feed=refused altered-archive=refused single-copy \$single_copy/,
  );
  const published = source.slice(
    source.indexOf("prove_published()"),
    source.indexOf('if [ "$mode" = published ]'),
  );
  assert.ok(published.lastIndexOf("launch_published") < published.indexOf("prove_single_copy"));
  assert.match(published, /\[ "\$single_copy" = pass \]/);
  const afterUpdate = source.slice(source.indexOf("pass update"));
  assert.ok(afterUpdate.indexOf("prove_single_copy") < afterUpdate.indexOf("pass feed-signature"));
  assert.match(afterUpdate, /\[ "\$single_copy" = pass \] \|\| exit 1/);
});

test("count_hermedbots_copies covers empty, one, two, wrong version, vanished, and build-dir copies", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hermed-copies-"));
  try {
    const keep = writeFakeApp(path.join(root, "keep.app"), "1.2.3");
    const extra = writeFakeApp(path.join(root, "extra.app"), "1.2.3");
    const stale = writeFakeApp(path.join(root, "stale.app"), "0.0.1");
    const built = writeFakeApp(path.join(root, "build", "Built.app"), "1.2.3");
    const gone = path.join(root, "gone.app");
    const id = "com.hermedbots.HermedBots";

    const empty = countCopies({
      home: root,
      target: "1.2.3",
      mdfind: "",
      lsregister: "",
    });
    assert.notEqual(empty.status, 0);
    assert.match(empty.stdout, /single-copy count=0/);

    const one = countCopies({
      home: root,
      target: "1.2.3",
      mdfind: `${keep}\n`,
      lsregister: lsregisterDump([{ path: keep, id }]),
    });
    assert.equal(one.status, 0, one.stderr);
    assert.match(one.stdout, /single-copy count=1/);
    assert.match(one.stdout, /copy version=1\.2\.3 path=~\/keep\.app/);

    const two = countCopies({
      home: root,
      target: "1.2.3",
      mdfind: `${keep}\n${extra}\n`,
      lsregister: lsregisterDump([
        { path: keep, id },
        { path: extra, id },
      ]),
    });
    assert.notEqual(two.status, 0);
    assert.match(two.stdout, /single-copy count=2/);

    const wrong = countCopies({
      home: root,
      target: "1.2.3",
      mdfind: `${stale}\n`,
      lsregister: "",
    });
    assert.notEqual(wrong.status, 0);
    assert.match(wrong.stdout, /single-copy count=1/);
    assert.match(wrong.stdout, /copy version=0\.0\.1 /);

    const vanished = countCopies({
      home: root,
      target: "1.2.3",
      mdfind: `${gone}\n${keep}\n`,
      lsregister: lsregisterDump([{ path: gone, id }]),
    });
    assert.equal(vanished.status, 0, vanished.stderr);
    assert.match(vanished.stdout, /single-copy count=1/);
    assert.doesNotMatch(vanished.stdout, /gone\.app/);

    const excluded = countCopies({
      home: root,
      buildDir: path.join(root, "build"),
      target: "1.2.3",
      mdfind: `${keep}\n${built}\n`,
      lsregister: lsregisterDump([{ path: built, id }]),
    });
    assert.equal(excluded.status, 0, excluded.stderr);
    assert.match(excluded.stdout, /single-copy count=1/);
    assert.doesNotMatch(excluded.stdout, /Built\.app/);

    const leaked = `${one.stdout}\n${two.stdout}\n${empty.stdout}\n${wrong.stdout}\n${vanished.stdout}\n${excluded.stdout}`;
    assert.doesNotMatch(leaked, /\/Users\/|\/home\/[^/\s]+/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
