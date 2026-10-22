"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const planPath = process.env.PLAN_FILE || join(__dirname, "../docs/plans/hermed-bots.md");
const plan = readFileSync(planPath, "utf8");
const lines = plan.split("\n");

const ids = (text) => [...text.matchAll(/HD-(\d+)/g)].map((m) => `HD-${m[1]}`);

function expand(text) {
  // "HD-08 to HD-15" is a range, other mentions are single units
  const out = new Set();
  for (const m of text.matchAll(/HD-(\d+) to HD-(\d+)/g)) {
    for (let n = Number(m[1]); n <= Number(m[2]); n++) out.add(`HD-${String(n).padStart(2, "0")}`);
  }
  for (const id of ids(text.replace(/HD-\d+ to HD-\d+/g, ""))) out.add(id);
  return out;
}

// Section dependencies: "**Depends on.** HD-04 and HD-07."
const sections = new Map();
let current = null;
for (const line of lines) {
  const head = line.match(/^## .*\((HD-\d+)\)$/);
  if (head) {
    current = { id: head[1], deps: new Set(), created: new Set(), refs: new Set(), lines: [] };
    sections.set(current.id, current);
    continue;
  }
  if (!current) continue;
  if (/^## /.test(line)) {
    current = null;
    continue;
  }
  current.lines.push(line);
  const dep = line.match(/^\*\*Depends on\.\*\* (.*)$/);
  if (dep) current.deps = expand(dep[1]);
  const create = line.match(/^- \[ \] Create (.*)$/);
  const paths = [...line.matchAll(/`([^`\s]+\.(?:swift|md|sh|js|mjs|yml))`/g)].map((m) => m[1]);
  if (create) {
    for (const p of paths) current.created.add(p);
    // "Create `A.swift` and `B.swift`" lists share the line, all of them are created here
  } else {
    for (const p of paths) current.refs.add(p);
  }
}

// Graph: "  - [ ] HD-08 after HD-04 and HD-07." under "Follow this dependency graph."
const graph = new Map();
for (const line of lines) {
  const m = line.match(/^ {2}- \[ \] (HD-[\d, and HD-]+?) (?:is first|after (.*?))\.(?: .*)?$/);
  if (!m) continue;
  const parents = m[2] ? expand(m[2]) : new Set();
  for (const id of ids(m[1])) graph.set(id, parents);
}

function ancestors(id, seen = new Set()) {
  for (const parent of sections.get(id).deps) {
    if (!seen.has(parent)) {
      seen.add(parent);
      ancestors(parent, seen);
    }
  }
  return seen;
}

test("the plan has sixteen units with a graph entry each", () => {
  assert.equal(sections.size, 16);
  assert.deepEqual([...graph.keys()].sort(), [...sections.keys()].sort());
});

test("graph and section Depends on lines list the same parents", () => {
  for (const [id, section] of sections) {
    if (id === "HD-01") continue;
    assert.deepEqual([...graph.get(id)].sort(), [...section.deps].sort(), id);
  }
});

test("a unit depends only on lower numbered units", () => {
  for (const [id, section] of sections) {
    for (const dep of section.deps) assert.ok(dep < id, `${id} depends on ${dep}`);
  }
});

test("a file a unit reads is created by that unit or by an ancestor", () => {
  const owner = new Map();
  for (const [id, section] of sections) for (const p of section.created) owner.set(p, id);
  for (const [id, section] of sections) {
    const reachable = ancestors(id);
    reachable.add(id);
    for (const p of section.refs) {
      const maker = owner.get(p);
      if (maker) assert.ok(reachable.has(maker), `${id} reads ${p} created by ${maker}`);
    }
  }
});

test("the HD-08 lanes do not read the conversation view that HD-09 creates", () => {
  const hd08 = sections.get("HD-08").lines.join("\n");
  assert.doesNotMatch(hd08, /hd\.conversation\./);
  assert.match(sections.get("HD-09").lines.join("\n"), /hd\.conversation\.view/);
});

test("the approval sheet and the error banner precede the units that use them", () => {
  for (const id of ["HD-13", "HD-14", "HD-15"]) {
    assert.ok(ancestors(id).has("HD-11"), `${id} needs HD-11`);
  }
  assert.ok(ancestors("HD-13").has("HD-12"));
  assert.ok(ancestors("HD-06").has("HD-04"));
});
