"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const APP_SWIFT = join(ROOT, "HermedBots");

function walkSwift(dir, files = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) walkSwift(path, files);
    else if (entry.name.endsWith(".swift")) files.push(path);
  }
  return files;
}

function sshG(configPath, alias) {
  return spawnSync("/usr/bin/ssh", ["-G", "-F", configPath, alias], {
    encoding: "utf8",
  });
}

test("ssh -G resolves a Match block reached through Include", () => {
  const dir = mkdtempSync(join(tmpdir(), "hb-ssh-g-"));
  try {
    const included = join(dir, "inc.conf");
    const config = join(dir, "config");
    writeFileSync(
      included,
      [
        "Match originalhost lab.invalid",
        "  User operator",
        "  Port 2222",
        "  Hostname gateway.example.invalid",
        "  IdentityFile /tmp/fake-id.invalid",
        "",
      ].join("\n"),
    );
    writeFileSync(config, `Include ${included}\n`);
    const run = sshG(config, "lab.invalid");
    assert.equal(run.status, 0, run.stderr);
    const values = {};
    for (const line of run.stdout.split("\n")) {
      const text = line.trim();
      const space = text.indexOf(" ");
      if (space < 1) continue;
      const key = text.slice(0, space).toLowerCase();
      const value = text.slice(space + 1);
      if (!values[key]) values[key] = [];
      values[key].push(value);
    }
    assert.equal(values.hostname?.[0], "gateway.example.invalid");
    assert.equal(values.user?.[0], "operator");
    assert.equal(values.port?.[0], "2222");
    assert.equal(values.identityfile?.[0], "/tmp/fake-id.invalid");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

function appReadsSshConfig(text) {
  if (/\.ssh\/config/.test(text)) return true;
  if (!/\.ssh/.test(text)) return false;
  return (
    /contents\(atPath:/.test(text) ||
    /String\s*\(\s*contentsOf/.test(text) ||
    /Data\s*\(\s*contentsOf/.test(text) ||
    /contentsOfFile/.test(text)
  );
}

test("the source scan fails when app Swift reads the user ssh config", () => {
  assert.equal(appReadsSshConfig('let p = home.appending("/.ssh/config")'), true);
  assert.equal(appReadsSshConfig('String(contentsOf: url)\nlet dir = ".ssh"'), true);
  assert.equal(appReadsSshConfig("FileManager.default.contents(atPath: path + \".ssh\")"), true);
  assert.equal(appReadsSshConfig("Data(contentsOf: url)"), false);
});

test("app Swift never reads ~/.ssh/config and no longer refuses Match", () => {
  const forbidden = [
    /matchBlockRefused/,
    /hasMatchBlock/,
    /checking match for/,
    /namesAlias/,
    /"-vv"/,
  ];
  for (const file of walkSwift(APP_SWIFT)) {
    const text = readFileSync(file, "utf8");
    assert.equal(appReadsSshConfig(text), false, `${file} reads an ssh config file`);
    for (const pattern of forbidden) {
      assert.equal(pattern.test(text), false, `${file} still matches ${pattern}`);
    }
  }
});
