"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const PROOF = "scripts/homebrew-install-proof.sh";
const cask = "eliasprunaire/tap/hermed-bots";

function plist(version) {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<plist version=\"1.0\"><dict>",
    "<key>CFBundleShortVersionString</key>",
    `<string>${version}</string>`,
    "<key>CFBundleVersion</key>",
    `<string>${version}</string>`,
    "<key>CFBundleExecutable</key>",
    "<string>HermedBots</string>",
    "</dict></plist>",
    "",
  ].join("\n");
}

function writeTool(dir, name, body) {
  fs.writeFileSync(path.join(dir, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
}

function run({
  args = ["run"],
  brew = {},
  codesign = 0,
  spctl = 0,
  leftover = false,
  staleProcess = false,
  openOk = true,
  version = "0.1.2",
  env = {},
  pgrep = "file",
} = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "hermed-brew-proof-"));
  const calls = path.join(dir, "calls");
  const listed = path.join(dir, "listed");
  const running = path.join(dir, "running");
  const apps = path.join(dir, "apps");
  const app = path.join(apps, "HermedBots.app");
  fs.mkdirSync(apps, { recursive: true });
  if (leftover) {
    fs.mkdirSync(path.join(app, "Contents", "MacOS"), { recursive: true });
    fs.writeFileSync(path.join(app, "Contents", "Info.plist"), plist(version));
    fs.writeFileSync(listed, "1");
  }
  if (staleProcess) fs.writeFileSync(running, "1");
  writeTool(dir, "uname", 'echo Darwin');
  writeTool(
    dir,
    "brew",
    [
      `printf '%s\\n' "brew $*" >> ${calls}`,
      `if [ "$1" = info ]; then`,
      `  printf '%s\\n' '{"casks":[{"token":"hermed-bots","version":"${version}"}]}'`,
      `  exit ${brew.info ?? 0}`,
      `fi`,
      `if [ "$1" = list ]; then`,
      `  [ -f ${listed} ] && exit 0`,
      `  exit 1`,
      `fi`,
      `if [ "$1" = install ]; then`,
      `  mkdir -p '${app}/Contents/MacOS'`,
      `  printf '%s\\n' '${plist(version).replace(/'/g, `'\\''`)}' > '${app}/Contents/Info.plist'`,
      `  printf '%s\\n' '#!/bin/sh' > '${app}/Contents/MacOS/HermedBots'`,
      `  chmod 755 '${app}/Contents/MacOS/HermedBots'`,
      `  echo 1 > ${listed}`,
      `  echo 1 > ${dir}/installed`,
      `  exit ${brew.install ?? 0}`,
      `fi`,
      `if [ "$1" = uninstall ]; then`,
      `  rm -f ${listed}`,
      `  rm -rf '${app}'`,
      `  exit ${brew.uninstall ?? 0}`,
      `fi`,
      `exit 1`,
    ].join("\n"),
  );
  writeTool(dir, "codesign", `printf '%s\\n' "codesign $*" >> ${calls}; exit ${codesign}`);
  writeTool(dir, "spctl", `printf '%s\\n' "spctl $*" >> ${calls}; exit ${spctl}`);
  if (openOk) {
    writeTool(dir, "open", `printf '%s\\n' "open $*" >> ${calls}; echo 1 > ${running}; exit 0`);
  } else {
    writeTool(dir, "open", `printf '%s\\n' "open $*" >> ${calls}; exit 1`);
  }
  writeTool(dir, "nohup", `printf '%s\\n' "nohup $*" >> ${calls}; exit 0`);
  if (pgrep === "once") {
    writeTool(
      dir,
      "pgrep",
      [
        `[ ! -f ${dir}/installed ] && { [ -f ${running} ] && echo 4242 && exit 0; exit 1; }`,
        `n=$(cat ${dir}/pn 2>/dev/null || echo 0); n=$((n + 1)); echo $n > ${dir}/pn`,
        `[ "$n" = 1 ] && echo 4242 && exit 0`,
        `exit 1`,
      ].join("\n"),
    );
  } else {
    writeTool(dir, "pgrep", `[ -f ${running} ] && echo 4242 && exit 0; exit 1`);
  }
  writeTool(dir, "kill", `printf '%s\\n' "kill $*" >> ${calls}; rm -f ${running}; exit 0`);
  writeTool(
    dir,
    "PlistBuddy",
    [
      `printf '%s\\n' "PlistBuddy $*" >> ${calls}`,
      `key=$2`,
      `key=\${key#Print :}`,
      `if [ "$key" = CFBundleShortVersionString ] || [ "$key" = CFBundleVersion ]; then echo '${version}'; exit 0; fi`,
      `if [ "$key" = CFBundleExecutable ]; then echo HermedBots; exit 0; fi`,
      `exit 1`,
    ].join("\n"),
  );
  const res = spawnSync("bash", [PROOF, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: `${dir}:${process.env.PATH}`,
      HOME: path.join(dir, "home"),
      PLISTBUDDY: path.join(dir, "PlistBuddy"),
      HOMEBREW_PROOF_APPDIR: apps,
      ...env,
    },
  });
  const lines = fs.existsSync(calls) ? fs.readFileSync(calls, "utf8").trim().split("\n").filter(Boolean) : [];
  return { res, lines, dir, app, listed, apps };
}

test("the Homebrew install proof is valid shell and keeps tracing off", () => {
  const syntax = spawnSync("bash", ["-n", PROOF], { encoding: "utf8" });
  assert.equal(syntax.status, 0, syntax.stderr);
  const source = fs.readFileSync(PROOF, "utf8");
  assert.match(source, /^set \+x$/m);
  assert.doesNotMatch(source, /SPARKLE_PRIVATE_KEY|DISTRIBUTION_TOKEN|APPLE_TEAM_ID/);
});

test("the Homebrew install proof refuses a machine that is not macOS and an unknown mode", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hermed-brew-os-"));
  try {
    writeTool(root, "uname", "echo Linux");
    const env = { ...process.env, PATH: `${root}:${process.env.PATH}` };
    const linux = spawnSync("bash", [PROOF, "dry-run"], { encoding: "utf8", env });
    assert.equal(linux.status, 2);
    assert.match(linux.stderr, /needs macOS/);
    const mode = spawnSync("bash", [PROOF, "prepare"], { encoding: "utf8", env });
    assert.equal(mode.status, 2);
    assert.match(mode.stderr, /Usage: homebrew-install-proof\.sh \[dry-run\|run\]/);
    const def = spawnSync("bash", [PROOF], { encoding: "utf8", env });
    assert.equal(def.status, 2);
    assert.match(def.stderr, /needs macOS/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("dry-run reads the tap cask and does not install", () => {
  const { res, lines } = run({ args: ["dry-run"] });
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /^PASS: cask eliasprunaire\/tap\/hermed-bots version=0\.1\.2$/m);
  assert.match(res.stdout, /^PASS: dry-run \(no install\)$/m);
  assert.match(
    res.stdout,
    /^HOMEBREW-INSTALL-PROOF version=0\.1\.2 expected=0\.1\.2 install=skip version-check=skip codesign=skip spctl=skip launch=skip uninstall=skip$/m,
  );
  assert.ok(lines.includes(`brew info --cask --json=v2 ${cask}`));
  assert.equal(lines.some((line) => line.startsWith("brew install")), false);
  assert.doesNotMatch(`${res.stdout}\n${res.stderr}`, /\/Users\/|\/home\/[^/\s]+/);
});

test("run installs from the tap, checks the bundle, launches, quits, and uninstalls", () => {
  const { res, lines, app, apps } = run();
  assert.equal(res.status, 0, `${res.stdout}\n${res.stderr}`);
  assert.ok(lines.includes(`brew install --cask --appdir=${apps} ${cask}`));
  assert.ok(lines.some((line) => line.startsWith("codesign --verify --deep --strict")));
  assert.ok(lines.some((line) => line.startsWith("spctl --assess --type execute")));
  assert.ok(lines.includes(`brew uninstall --cask --force ${cask}`));
  assert.match(res.stdout, /^PASS: brew install --cask eliasprunaire\/tap\/hermed-bots$/m);
  assert.match(res.stdout, /^PASS: installed version=0\.1\.2$/m);
  assert.match(res.stdout, /^PASS: codesign --verify$/m);
  assert.match(res.stdout, /^PASS: spctl --assess$/m);
  assert.match(res.stdout, /^PASS: launch and quit$/m);
  assert.match(res.stdout, /^PASS: brew uninstall --cask eliasprunaire\/tap\/hermed-bots$/m);
  assert.match(
    res.stdout,
    /^HOMEBREW-INSTALL-PROOF version=0\.1\.2 expected=0\.1\.2 install=pass version-check=pass codesign=pass spctl=pass launch=pass uninstall=pass$/m,
  );
  assert.equal(fs.existsSync(app), false);
  assert.doesNotMatch(`${res.stdout}\n${res.stderr}`, /\/Users\/|\/home\/[^/\s]+/);
});

test("a leftover cask is uninstalled before the install", () => {
  const { res, lines } = run({ leftover: true });
  assert.equal(res.status, 0, res.stdout);
  const list = lines.filter((line) => line.startsWith("brew list"));
  const uninstall = lines.filter((line) => line.startsWith("brew uninstall"));
  const install = lines.filter((line) => line.startsWith("brew install"));
  assert.ok(list.length >= 1);
  assert.ok(uninstall.length >= 2);
  assert.equal(install.length, 1);
  assert.match(res.stdout, /^PASS: leftover uninstall$/m);
});

test("a Gatekeeper refusal exits non-zero after install and does not count as a pass", () => {
  const { res, lines } = run({ spctl: 3 });
  assert.equal(res.status, 1);
  assert.match(res.stdout, /^FAIL: spctl --assess$/m);
  assert.match(res.stdout, /spctl=fail/);
  assert.doesNotMatch(res.stdout, /launch=pass/);
  assert.ok(lines.some((line) => line.startsWith("brew uninstall")));
});

test("a pinned version that is not the tap version fails before install", () => {
  const { res, lines } = run({ env: { HOMEBREW_PROOF_VERSION: "0.1.0" } });
  assert.equal(res.status, 1);
  assert.match(res.stdout, /^FAIL: HOMEBREW_PROOF_VERSION=0\.1\.0 does not match tap version=0\.1\.2$/m);
  assert.equal(lines.some((line) => line.startsWith("brew install")), false);
});

test("dry-run with a pinned version that is not the tap version exits non-zero", () => {
  const { res, lines } = run({ args: ["dry-run"], env: { HOMEBREW_PROOF_VERSION: "0.1.0" } });
  assert.equal(res.status, 1);
  assert.match(res.stdout, /^FAIL: HOMEBREW_PROOF_VERSION=0\.1\.0 does not match tap version=0\.1\.2$/m);
  assert.equal(lines.some((line) => line.startsWith("brew install")), false);
});

test("dry-run with a pinned version still fails when the tap cask cannot be read", () => {
  const { res } = run({
    args: ["dry-run"],
    brew: { info: 1 },
    env: { HOMEBREW_PROOF_VERSION: "0.1.2" },
  });
  assert.equal(res.status, 1);
  assert.match(res.stdout, /^FAIL: cask eliasprunaire\/tap\/hermed-bots is not readable from the tap$/m);
});

test("a brew uninstall that exits non-zero fails even after the files are gone", () => {
  const { res } = run({ brew: { uninstall: 1 } });
  assert.equal(res.status, 1, res.stdout);
  assert.match(res.stdout, /^FAIL: brew uninstall --cask eliasprunaire\/tap\/hermed-bots$/m);
  assert.match(res.stdout, /uninstall=fail/);
});

test("an app that exits during the startup delay is not a successful launch", () => {
  const { res } = run({ pgrep: "once" });
  assert.equal(res.status, 1, res.stdout);
  assert.match(res.stdout, /^FAIL: app exited before quit$/m);
  assert.match(res.stdout, /launch=fail/);
});

test("a leftover process is stopped before brew install and a failed open is not a pass", () => {
  const { res, lines } = run({
    staleProcess: true,
    openOk: false,
    env: { HOMEBREW_PROOF_LAUNCH_WAIT: "1" },
  });
  assert.equal(res.status, 1, res.stdout);
  const killAt = lines.findIndex((line) => line.startsWith("kill "));
  const installAt = lines.findIndex((line) => line.startsWith("brew install"));
  assert.ok(killAt !== -1 && installAt !== -1 && killAt < installAt, lines.join("\n"));
  assert.match(res.stdout, /^FAIL: app did not launch$/m);
  assert.match(res.stdout, /launch=fail/);
});

test("brew install passes --appdir from HOMEBREW_PROOF_APPDIR", () => {
  const { res, lines, apps } = run();
  assert.equal(res.status, 0, res.stdout);
  assert.equal(
    lines.filter((line) => line.startsWith("brew install")).join("\n"),
    `brew install --cask --appdir=${apps} ${cask}`,
  );
});

if (spawnSync("shellcheck", ["-V"], { encoding: "utf8" }).status === 0) {
  test("shellcheck accepts the Homebrew install proof", () => {
    const res = spawnSync("shellcheck", ["-x", PROOF], { encoding: "utf8" });
    assert.equal(res.status, 0, res.stdout + res.stderr);
  });
}
