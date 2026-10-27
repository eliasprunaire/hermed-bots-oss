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

test("app Swift never reads ~/.ssh/config and no longer refuses Match", () => {
  const forbidden = [
    /~\/\.ssh\/config/,
    /"\$HOME\/\.ssh\/config"/,
    /matchBlockRefused/,
    /hasMatchBlock/,
    /checking match for/,
    /namesAlias/,
  ];
  const reads = [
    /String\s*\(\s*contentsOfFile\s*:/,
    /Data\s*\(\s*contentsOf\s*:/,
    /contentsOf:\s*URL/,
  ];
  for (const file of walkSwift(APP_SWIFT)) {
    const text = readFileSync(file, "utf8");
    for (const pattern of forbidden) {
      assert.equal(pattern.test(text), false, `${file} still matches ${pattern}`);
    }
    if (/ssh\/config/.test(text) && reads.some((pattern) => pattern.test(text))) {
      assert.fail(`${file} reads an ssh config file`);
    }
  }
});
