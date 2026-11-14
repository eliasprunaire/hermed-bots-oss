"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");

const {
  rewriteText,
  scanText,
} = require("../scripts/check-comment-period.js");

test("scanText flags a source comment that ends with a period", () => {
  assert.deepEqual(
    scanText("bad.js", "// commentaire fautif.\n", ".js"),
    ["bad.js:1: POINT_FINAL"],
  );
});

test("scanText ignores a JS template line that looks like a comment", () => {
  const text = [
    "const text = `",
    "// Ceci est une donnée.",
    "`;",
    "",
  ].join("\n");
  assert.deepEqual(scanText("ok.js", text, ".js"), []);
});

test("scanText ignores a Python triple-quoted line that looks like a comment", () => {
  const text = [
    "text = \"\"\"",
    "# Ceci est une donnée.",
    "\"\"\"",
    "",
  ].join("\n");
  assert.deepEqual(scanText("ok.py", text, ".py"), []);
});

test("scanText ignores a shell here-doc line that looks like a comment", () => {
  const text = [
    "cat <<EOF",
    "# Ceci est une donnée.",
    "EOF",
    "",
  ].join("\n");
  assert.deepEqual(scanText("ok.sh", text, ".sh"), []);
});

test("scanText still flags a comment inside a JS template expression", () => {
  const text = [
    "const text = `${",
    "// commentaire fautif.",
    "}`;",
    "",
  ].join("\n");
  assert.deepEqual(scanText("bad.js", text, ".js"), [
    "bad.js:2: POINT_FINAL",
  ]);
});

test("rewriteText leaves a period inside a JS template intact", () => {
  const text = [
    "const text = `",
    "// Ceci est une donnée.",
    "`;",
    "",
  ].join("\n");
  assert.equal(rewriteText(text, ".js"), text);
});
