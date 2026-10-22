"use strict";

const { readFileSync } = require("node:fs");
const { hitsIn } = require("./check-pr-attribution.js");

function main(argv = process.argv.slice(2)) {
  const path = argv[0];
  if (path == null || path === "") {
    console.error("usage: check-commit-msg.js <message-file>");
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
  const hits = hitsIn(text);
  if (hits.length === 0) {
    return 0;
  }
  for (const id of hits) {
    console.error(`commit message contains ${id}`);
  }
  return 1;
}

module.exports = { main };

if (require.main === module) {
  process.exitCode = main();
}
