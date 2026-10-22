"use strict";

const fs = require("node:fs");
const path = require("node:path");

const rules = require("./workflow-rules.js");

const HEADING = "## Rule to mechanism";

function parseRoot(argv) {
  if (argv.length === 0) {
    return path.resolve(__dirname, "..");
  }
  if (argv.length === 2 && argv[0] === "--root") {
    return path.resolve(argv[1]);
  }
  process.stderr.write("usage: node scripts/check-rule-table.js [--root DIR]\n");
  return null;
}

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (err) {
    if (err && err.code === "ENOENT") {
      return null;
    }
    throw err;
  }
}

function mechanismRows(markdown) {
  if (markdown == null) {
    return [];
  }
  const lines = markdown.split("\n");
  const start = lines.findIndex((line) => line.trim() === HEADING);
  if (start < 0) {
    return [];
  }
  const rows = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.startsWith("|")) {
      rows.push(line);
      continue;
    }
    if (line.trim() === "" && rows.length === 0) {
      continue;
    }
    break;
  }
  return rows;
}

function workflowScripts(root) {
  const dir = path.join(root, ".github", "workflows");
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch (err) {
    if (err && err.code === "ENOENT") {
      return [];
    }
    throw err;
  }
  const found = new Set();
  for (const name of names) {
    if (!name.endsWith(".yml") && !name.endsWith(".yaml")) {
      continue;
    }
    const text = fs.readFileSync(path.join(dir, name), "utf8");
    const re = /(?<![A-Za-z0-9_])scripts\/[A-Za-z0-9._-]+\.js/g;
    let match;
    while ((match = re.exec(text)) !== null) {
      found.add(match[0]);
    }
  }
  return [...found].sort();
}

function rowNamesScript(row, script) {
  const body = script.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`(?:^|[^A-Za-z0-9_])${body}(?![A-Za-z0-9_])`);
  return re.test(row);
}

function isFile(file) {
  try {
    return fs.statSync(file).isFile();
  } catch (err) {
    if (err && err.code === "ENOENT") {
      return false;
    }
    throw err;
  }
}

function checkRoot(root) {
  const errors = [];
  const rows = mechanismRows(readText(path.join(root, "AGENTS.md")));
  const listed = new Set();
  for (const rule of rules) {
    listed.add(rule.script);
    if (!isFile(path.join(root, rule.script))) {
      errors.push(`missing checker ${rule.script}`);
    }
    const named = rows.some((row) => rowNamesScript(row, rule.script));
    if (!named) {
      errors.push(`AGENTS.md lacks a row for ${rule.script}`);
    }
  }
  for (const script of workflowScripts(root)) {
    if (!listed.has(script)) {
      errors.push(`workflow names ${script} but the list omits it`);
    }
  }
  return errors;
}

function main(argv = process.argv.slice(2)) {
  const root = parseRoot(argv);
  if (root === null) {
    return 1;
  }
  const errors = checkRoot(root);
  if (errors.length > 0) {
    process.stderr.write(`${errors.join("\n")}\n`);
    return 1;
  }
  process.stdout.write("ok\n");
  return 0;
}

if (require.main === module) {
  process.exitCode = main();
}
