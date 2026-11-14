"use strict";

const { readFileSync, writeFileSync } = require("node:fs");
const { hitsIn, stripCoAuthoredBy } = require("./check-pr-attribution.js");

function parseArgv(argv) {
  let strip = false;
  let path;
  for (const arg of argv) {
    if (arg === "--strip") {
      strip = true;
      continue;
    }
    if (path == null) {
      path = arg;
    }
  }
  return { strip, path };
}

function main(argv = process.argv.slice(2)) {
  const { strip, path } = parseArgv(argv);
  if (path == null || path === "") {
    console.error("usage: check-commit-msg.js [--strip] <message-file>");
    return 1;
  }
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (err) {
    if (err && err.code === "ENOENT") {
      console.error(`missing file: ${path}`);
      return 1;
    }
    throw err;
  }
  if (strip) {
    const cleaned = stripCoAuthoredBy(text);
    if (cleaned !== text) {
      writeFileSync(path, cleaned);
      console.error("trailer Co-authored-by retiré du message de commit");
    }
    return 0;
  }
  const hits = hitsIn(text);
  if (hits.length === 0) {
    return 0;
  }
  for (const id of hits) {
    if (id === "Co-authored-by") {
      console.error("trailer Co-authored-by interdit dans le message de commit");
    }
    console.error(`commit message contains ${id}`);
  }
  return 1;
}

module.exports = { main };

if (require.main === module) {
  process.exitCode = main();
}
