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

function argvOf(command) {
  const text = normalizeCommand(command);
  const tokens = [];
  let i = 0;
  while (i < text.length) {
    while (i < text.length && /[ \t]/.test(text[i])) {
      i += 1;
    }
    if (i >= text.length) {
      break;
    }
    if (text[i] === "\n") {
      i += 1;
      continue;
    }
    const quote = text[i] === '"' || text[i] === "'" ? text[i] : "";
    if (quote !== "") {
      i += 1;
      let token = "";
      while (i < text.length && text[i] !== quote) {
        if (quote === '"' && text[i] === "\\" && i + 1 < text.length) {
          token += text[i + 1];
          i += 2;
          continue;
        }
        token += text[i];
        i += 1;
      }
      if (i < text.length && text[i] === quote) {
        i += 1;
      }
      tokens.push(token);
      continue;
    }
    let token = "";
    while (i < text.length && !/[ \t\n]/.test(text[i])) {
      if (text[i] === "\\" && i + 1 < text.length) {
        token += text[i + 1];
        i += 2;
        continue;
      }
      token += text[i];
      i += 1;
    }
    tokens.push(token);
  }
  return tokens;
}

function flagValues(tokens) {
  const values = [];
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token === "--trailer" || token === "-m" || token === "--message") {
      if (i + 1 < tokens.length) {
        i += 1;
        values.push(tokens[i]);
      }
      continue;
    }
    if (token.startsWith("--trailer=")) {
      values.push(token.slice("--trailer=".length));
      continue;
    }
    if (token.startsWith("--message=")) {
      values.push(token.slice("--message=".length));
      continue;
    }
    if (token.startsWith("-m") && token.length > 2) {
      values.push(token.slice(2));
    }
  }
  return values;
}

function textHasCoAuthoredBy(text) {
  const normalized = normalizeCommand(text);
  if (hitsIn(normalized).includes("Co-authored-by")) {
    return true;
  }
  return normalized.split("\n").some((line) => isCoAuthoredByLine(line));
}

function commandHasCoAuthoredBy(command) {
  if (textHasCoAuthoredBy(command)) {
    return true;
  }
  return flagValues(argvOf(command)).some((value) => textHasCoAuthoredBy(value));
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
