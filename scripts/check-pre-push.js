"use strict";

const { readFileSync } = require("node:fs");

const MAIN_REF = "refs/heads/main";

function main(text) {
  for (const raw of String(text).split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (line === "") {
      continue;
    }
    const parts = line.split(" ");
    if (parts.length !== 4 || parts.some((part) => part.length === 0)) {
      console.error("malformed pre-push update");
      return 1;
    }
    if (parts[2].toLowerCase() === MAIN_REF) {
      console.error(`refusing push to ${MAIN_REF}`);
      return 1;
    }
  }
  return 0;
}

module.exports = { main };

if (require.main === module) {
  process.exitCode = main(readFileSync(0, "utf8"));
}
