"use strict";

// The facade files describe results, not the infrastructure they run on. Apart from the two
// generic loopback examples, no file names an address, a host or a local path.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "../..");
const SELF = path.join(root, "test/facade/contract.test.js");
const EXTRA = ["docs/facade.md", "docs/spike/pr1-write-routes.md", "README.md"].map((f) => path.join(root, f));

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(full) : [full];
  });
}

const files = [...walk(path.join(root, "facade")), ...walk(path.join(root, "test/facade")), ...EXTRA].filter((f) => f !== SELF && /\.(js|md)$/.test(f));

const RULES = [
  ["an IPv4 literal", /(?<![\d.])(?!127\.0\.0\.1(?![\d.]))\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?![\d.])/],
  ["an IPv6 literal", /(?<![\w:]):{2}(?![\w:])|[0-9a-f]{0,4}:{2}[0-9a-f]{1,4}\b|\b(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\b/i],
  ["an internal host name", /\b[a-z0-9-]+\.(?:local|lan|corp|home\.arpa)\b/i],
  ["a local path", /\/(?:Users|home|root|var\/folders|private\/var)\/[^\s<"'`]+/],
];

test("contract: no file names an address other than the loopback examples, a host name or a local path", () => {
  assert.ok(files.length > 15, "the scan covers the facade, its tests and its docs");
  const found = [];
  files.forEach((file) => {
    fs.readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      for (const [label, re] of RULES) if (re.test(line)) found.push(`${path.relative(root, file)}:${i + 1}: ${label}`);
    });
  });
  assert.deepEqual(found, []);
});

test("contract: the rules themselves catch what they should", () => {
  const hit = (text) => RULES.filter(([, re]) => re.test(text)).map(([label]) => label);
  assert.deepEqual(hit("host 127.0.0.1 port 0"), []);
  assert.deepEqual(hit("localhost and 0.22.5"), []);
  assert.deepEqual(hit(`at ${[10, 0, 0, 7].join(".")}`), ["an IPv4 literal"]);
  assert.deepEqual(hit(`${[127, 0, 0, 12].join(".")}`), ["an IPv4 literal"]);
  assert.deepEqual(hit(`listen on ${":".repeat(2)}`), ["an IPv6 literal"]);
  assert.deepEqual(hit(`${"fe80"}${":".repeat(2)}${"1"}`), ["an IPv6 literal"]);
  assert.deepEqual(hit(`host ${"box"}.${"local"}`), ["an internal host name"]);
  assert.deepEqual(hit(`${"/home"}/someone/file`), ["a local path"]);
  assert.deepEqual(hit("2026-10-29T12:00:00Z"), []);
});
