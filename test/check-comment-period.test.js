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

test("scanText flags a comment after a regex that contains a backtick", () => {
  const text = [
    "const re = /`/;",
    "// commentaire fautif.",
    "",
  ].join("\n");
  assert.deepEqual(scanText("bad.js", text, ".js"), [
    "bad.js:2: POINT_FINAL",
  ]);
});

test("scanText ignores a JS template after a regex that contains a backtick", () => {
  const text = [
    "const re = /`/;",
    "const text = `",
    "// Ceci est une donnée.",
    "`;",
    "",
  ].join("\n");
  assert.deepEqual(scanText("ok.js", text, ".js"), []);
});

test("scanText flags a comment after regex literals in expression positions", () => {
  const snippets = [
    "fn(/`/);",
    "fn(1, /`/);",
    "const re = /`/;",
    "const o = { k: /`/ };",
    "const a = [/`/];",
    "const v = !/`/.test('');",
    "{ /`/; }",
    "function f() {}\n/`/;",
    "return /`/;",
  ];
  for (const snippet of snippets) {
    const text = `${snippet}\n// commentaire fautif.\n`;
    assert.deepEqual(
      scanText("bad.js", text, ".js"),
      [`bad.js:${snippet.split("\n").length + 1}: POINT_FINAL`],
      snippet,
    );
  }
});

test("scanText keeps division slashes out of regex mode", () => {
  const snippets = [
    "const n = ident / 2;",
    "const n = 4 / 2;",
    "const n = (1 + 2) / 3;",
    "const n = arr[0] / 2;",
    'const n = "x" / 2;',
  ];
  for (const snippet of snippets) {
    const text = [
      snippet,
      "// commentaire fautif.",
      "const text = `",
      "// Ceci est une donnée.",
      "`;",
      "",
    ].join("\n");
    assert.deepEqual(
      scanText("bad.js", text, ".js"),
      ["bad.js:2: POINT_FINAL"],
      snippet,
    );
  }
});

test("scanText flags a comment after a here-string", () => {
  const snippets = [
    "cat <<< EOF",
    "cat <<<'EOF'",
    'cat <<< "$raw"',
  ];
  for (const snippet of snippets) {
    const text = `${snippet}\n# commentaire fautif.\n`;
    assert.deepEqual(
      scanText("bad.sh", text, ".sh"),
      ["bad.sh:2: POINT_FINAL"],
      snippet,
    );
  }
});

test("scanText reads the full here-doc delimiter including quotes and hyphens", () => {
  const forms = [
    ["cat <<END-DATA", "END-DATA"],
    ["cat <<'EOF'", "EOF"],
    ['cat <<"EOF"', "EOF"],
    ["cat <<-'EOF'", "EOF"],
    ["cat <<'END DATA'", "END DATA"],
    ['cat <<E"O"F', "EOF"],
    ["cat <<\\EOF", "EOF"],
  ];
  for (const [open, close] of forms) {
    const text = [
      open,
      "# Ceci est une donnée.",
      close,
      "# commentaire fautif.",
      "",
    ].join("\n");
    assert.deepEqual(
      scanText("bad.sh", text, ".sh"),
      ["bad.sh:4: POINT_FINAL"],
      open,
    );
  }
});

test("scanText does not treat an arithmetic shift as a here-doc", () => {
  const snippets = [
    "echo $((1<<n))",
    "echo $(( 1 << n ))",
    "((x <<= 1))",
  ];
  for (const snippet of snippets) {
    const text = `${snippet}\n# commentaire fautif.\n`;
    assert.deepEqual(
      scanText("bad.sh", text, ".sh"),
      ["bad.sh:2: POINT_FINAL"],
      snippet,
    );
  }
});
