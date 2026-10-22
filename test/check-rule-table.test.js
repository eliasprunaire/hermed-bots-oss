"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..");
const script = join(root, "scripts/check-rule-table.js");
const rules = require("../scripts/workflow-rules.js");

const LISTED = [
  "scripts/verdict-gate.js",
  "scripts/check-pr-attribution.js",
  "scripts/check-main-push.js",
  "scripts/check-plans.js",
];

function run(args) {
  return spawnSync(process.execPath, [script, ...args], {
    cwd: root,
    encoding: "utf8",
  });
}

function writePassingTree(dir) {
  mkdirSync(join(dir, ".github", "workflows"), { recursive: true });
  mkdirSync(join(dir, "scripts"), { recursive: true });
  cpSync(join(root, "AGENTS.md"), join(dir, "AGENTS.md"));
  for (const name of readdirSync(join(root, ".github", "workflows"))) {
    if (name.endsWith(".yml") || name.endsWith(".yaml")) {
      cpSync(
        join(root, ".github", "workflows", name),
        join(dir, ".github", "workflows", name),
      );
    }
  }
  for (const rule of rules) {
    writeFileSync(join(dir, rule.script), "");
  }
}

function withTree(mutate) {
  const dir = mkdtempSync(join(tmpdir(), "check-rule-table-"));
  try {
    writePassingTree(dir);
    mutate(dir);
    return run(["--root", dir]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function deleteAttributionRows(markdown) {
  const lines = markdown.split("\n");
  const start = lines.findIndex((line) => line.trim() === "## Rule to mechanism");
  assert.ok(start >= 0);
  let inTable = false;
  const kept = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (i > start && line.startsWith("|")) {
      inTable = true;
      if (line.includes("scripts/check-pr-attribution.js")) {
        continue;
      }
    } else if (inTable && !line.startsWith("|")) {
      inTable = false;
    }
    kept.push(line);
  }
  return kept.join("\n");
}

test("a matching table exits 0", () => {
  assert.ok(Array.isArray(rules));
  assert.equal(Object.isFrozen(rules), true);
  const scripts = rules.map((rule) => rule.script);
  for (const listed of LISTED) {
    assert.ok(scripts.includes(listed), listed);
  }
  for (const rule of rules) {
    assert.equal(typeof rule.rule, "string");
    assert.equal(typeof rule.script, "string");
    assert.equal(typeof rule.test, "string");
    assert.equal(typeof rule.job, "string");
    assert.equal(Object.isFrozen(rule), true);
  }
  const result = run([]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "ok\n");
  assert.equal(result.stderr, "");
});

test("a missing checker path exits 1", () => {
  const result = withTree((dir) => {
    rmSync(join(dir, "scripts/check-plans.js"));
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /missing checker scripts\/check-plans\.js/);
  assert.doesNotMatch(result.stdout, /ok/);
});

test("a table with the attribution row deleted exits 1", () => {
  const result = withTree((dir) => {
    const agents = join(dir, "AGENTS.md");
    writeFileSync(agents, deleteAttributionRows(readFileSync(agents, "utf8")));
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /AGENTS\.md lacks a row for scripts\/check-pr-attribution\.js/);
  assert.doesNotMatch(result.stderr, /missing checker scripts\/check-pr-attribution\.js/);
  assert.doesNotMatch(result.stdout, /ok/);
});

test("a workflow that names a scripts js checker the list omits exits 1", () => {
  const result = withTree((dir) => {
    writeFileSync(
      join(dir, ".github", "workflows", "orphan.yml"),
      "jobs:\n  orphan:\n    steps:\n      - run: node scripts/orphan-checker.js\n",
    );
  });
  assert.equal(result.status, 1);
  assert.match(
    result.stderr,
    /workflow names scripts\/orphan-checker\.js but the list omits it/,
  );
  assert.doesNotMatch(result.stdout, /ok/);
});
