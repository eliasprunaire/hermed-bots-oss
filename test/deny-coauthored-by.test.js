"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const {
  commandHasCoAuthoredBy,
  decide,
} = require("../.cursor/hooks/deny-coauthored-by.js");

const root = join(__dirname, "..");
const hook = join(root, ".cursor", "hooks", "deny-coauthored-by.js");
const config = join(root, ".cursor", "hooks.json");

function runHook(payload) {
  return spawnSync(process.execPath, [hook], {
    cwd: root,
    encoding: "utf8",
    input: JSON.stringify(payload),
  });
}

test("hooks.json points the cloud agent hook at the deny script", () => {
  const parsed = JSON.parse(readFileSync(config, "utf8"));
  assert.equal(parsed.version, 1);
  const hooks = parsed.hooks.beforeShellExecution;
  assert.equal(Array.isArray(hooks), true);
  assert.equal(hooks[0].command, "node .cursor/hooks/deny-coauthored-by.js");
  assert.equal(hooks[0].matcher, "*");
});

test("a clean git commit command is allowed", () => {
  assert.equal(commandHasCoAuthoredBy("git commit -m feat: land the merge"), false);
  assert.deepEqual(decide({ command: "git commit -m feat: land the merge" }), {
    permission: "allow",
  });
});

test("a Co-authored-by line in the command is denied, with no allowlist", () => {
  const cursor =
    "git commit -m feat: land\n\nCo-authored-by: Cursor Agent <cursoragent@cursor.com>";
  const human =
    "git commit -m feat: land\n\nCo-authored-by: Human Reviewer <human@example.com>";
  assert.equal(commandHasCoAuthoredBy(cursor), true);
  assert.equal(commandHasCoAuthoredBy(human), true);
  assert.equal(decide({ command: cursor }).permission, "deny");
  assert.equal(decide({ command: human }).permission, "deny");
});

test("stdin JSON from beforeShellExecution denies a trailer", () => {
  const result = runHook({
    command:
      "git commit -m feat: land\n\nCo-authored-by: Bot <bot@example.com>",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), {
    permission: "deny",
    agent_message: "Co-authored-by lines are not allowed.",
  });
});

test("stdin JSON from beforeShellExecution allows a clean command", () => {
  const result = runHook({ command: "git commit -m feat: land the merge" });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { permission: "allow" });
});

test("a quoted --trailer Co-authored-by argument is denied", () => {
  const command =
    'git commit -m "feat: change" --trailer "Co-authored-by: Reviewer <reviewer@example.com>"';
  assert.equal(commandHasCoAuthoredBy(command), true);
  assert.equal(decide({ command }).permission, "deny");
  const result = runHook({ command });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).permission, "deny");
});

test("a quoted -m Co-authored-by argument is denied", () => {
  const command =
    'git commit -m "Co-authored-by: Reviewer <reviewer@example.com>"';
  assert.equal(commandHasCoAuthoredBy(command), true);
  assert.equal(decide({ command }).permission, "deny");
});

test("an equals --trailer Co-authored-by argument is denied", () => {
  const command =
    "git commit -m feat --trailer=Co-authored-by: Reviewer <reviewer@example.com>";
  assert.equal(decide({ command }).permission, "deny");
});

test("a quoted Signed-off-by trailer stays allowed", () => {
  const command =
    'git commit -m "feat: change" --trailer "Signed-off-by: Reviewer <reviewer@example.com>"';
  assert.equal(commandHasCoAuthoredBy(command), false);
  assert.equal(decide({ command }).permission, "allow");
});

test("a quoted --message Co-authored-by argument is denied", () => {
  const command =
    'git commit --message "Co-authored-by: Reviewer <reviewer@example.com>"';
  assert.equal(decide({ command }).permission, "deny");
});

test("an equals --message Co-authored-by argument is denied", () => {
  const command =
    "git commit --message=Co-authored-by: Reviewer <reviewer@example.com>";
  assert.equal(decide({ command }).permission, "deny");
});

test("a lowercase quoted --trailer Co-authored-by argument is denied", () => {
  const command =
    'git commit -m feat --trailer "co-authored-by: Reviewer <reviewer@example.com>"';
  assert.equal(decide({ command }).permission, "deny");
});

test("a search command that only mentions Co-authored-by stays allowed", () => {
  const command = 'rg "Co-authored-by:"';
  assert.equal(commandHasCoAuthoredBy(command), false);
  assert.equal(decide({ command }).permission, "allow");
});
