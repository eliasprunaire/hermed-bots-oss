"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const ALIAS = "example.invalid";
const RESOLVED_PORT = "2200";

function sshG(configPath, alias) {
  return spawnSync("/usr/bin/ssh", ["-G", "-F", configPath, alias], {
    encoding: "utf8",
  });
}

function dumpPort(stdout) {
  for (const line of stdout.split("\n")) {
    const text = line.trim();
    const space = text.indexOf(" ");
    if (space < 1) continue;
    if (text.slice(0, space).toLowerCase() === "port") return text.slice(space + 1).trim();
  }
  return undefined;
}

function withConfig(body, fn) {
  const dir = mkdtempSync(join(tmpdir(), "hb-ssh-port-"));
  try {
    const config = join(dir, "config");
    writeFileSync(config, body);
    return fn(config);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("ssh -G resolves a non-default port for an alias", () => {
  withConfig(`Host ${ALIAS}\n  Hostname ${ALIAS}\n  Port ${RESOLVED_PORT}\n`, (config) => {
    const run = sshG(config, ALIAS);
    assert.equal(run.status, 0, run.stderr);
    assert.equal(dumpPort(run.stdout), RESOLVED_PORT);
  });
});

test("ssh -G reports the OpenSSH default when the alias has no Port", () => {
  withConfig(`Host ${ALIAS}\n  Hostname ${ALIAS}\n`, (config) => {
    const run = sshG(config, ALIAS);
    assert.equal(run.status, 0, run.stderr);
    assert.equal(dumpPort(run.stdout), "22");
  });
});

test("ssh -G fails on an unreadable Port line", () => {
  withConfig(`Host ${ALIAS}\n  Port\n`, (config) => {
    const run = sshG(config, ALIAS);
    assert.notEqual(run.status, 0);
  });
});

test("the displayed port comes from ssh -G and the launch still omits -p", () => {
  const policy = readFileSync(
    join(ROOT, "Packages/HermesAdapter/Sources/AppSettings/SSHDisplayedPort.swift"),
    "utf8",
  );
  assert.match(policy, /static let fallback = 22/);
  assert.match(policy, /Port \(config SSH\)/);
  assert.match(policy, /readOnly\(resolvedPort:/);

  const settings = readFileSync(join(ROOT, "HermedBots/Settings/ConnectionView.swift"), "utf8");
  assert.match(settings, /displayedPort\?\.settingsTitle/);
  assert.match(settings, /displayedPort\?\.settingsValue/);

  const status = readFileSync(join(ROOT, "HermedBots/App/HermedBotsApp.swift"), "utf8");
  assert.match(status, /displayedPort/);
  assert.match(status, /statusPort/);

  const model = readFileSync(join(ROOT, "HermedBots/App/AppModel.swift"), "utf8");
  assert.match(model, /displayedPort = \.readOnly\(resolvedPort: next\.port\)/);
  assert.match(model, /displayedPort = \.readOnly\(resolvedPort: nil\)/);

  const tunnel = readFileSync(join(ROOT, "HermedBots/Transport/SSHTunnel.swift"), "utf8");
  const start = tunnel.indexOf("static func arguments(_ invocation");
  const end = tunnel.indexOf("private static func common");
  assert.ok(start >= 0 && end > start);
  const argsFn = tunnel.slice(start, end);
  assert.equal(argsFn.includes('"-p"'), false);
});
