"use strict";

const { hitsIn, isCoAuthoredByLine } = require("../../scripts/check-pr-attribution.js");

function commandOf(input) {
  if (input == null || typeof input !== "object") {
    return "";
  }
  if (typeof input.command === "string") {
    return input.command;
  }
  const toolInput = input.tool_input;
  if (
    toolInput != null &&
    typeof toolInput === "object" &&
    typeof toolInput.command === "string"
  ) {
    return toolInput.command;
  }
  return "";
}

function normalizeCommand(command) {
  return String(command).replace(/\\r\\n/g, "\n").replace(/\\n/g, "\n");
}

function commandHasCoAuthoredBy(command) {
  const text = normalizeCommand(command);
  if (hitsIn(text).includes("Co-authored-by")) {
    return true;
  }
  return text.split("\n").some((line) => isCoAuthoredByLine(line));
}

function decide(input) {
  if (!commandHasCoAuthoredBy(commandOf(input))) {
    return { permission: "allow" };
  }
  return {
    permission: "deny",
    agent_message: "Co-authored-by lines are not allowed.",
  };
}

function main() {
  const chunks = [];
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    chunks.push(chunk);
  });
  process.stdin.on("end", () => {
    let input = {};
    try {
      input = JSON.parse(chunks.join("") || "{}");
    } catch {
      input = {};
    }
    process.stdout.write(`${JSON.stringify(decide(input))}\n`);
  });
}

module.exports = { commandOf, commandHasCoAuthoredBy, decide };

if (require.main === module) {
  main();
}
