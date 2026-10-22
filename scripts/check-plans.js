"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const checker = path.join(root, "scripts/check-plan.mjs");

function planFiles(dir) {
  return fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((entry) => {
      return entry.isFile() && entry.name.endsWith(".md") && entry.name !== "README.md";
    })
    .map((entry) => path.join(dir, entry.name))
    .sort();
}

function main(argv = process.argv.slice(2)) {
  const dir = argv.length > 0 ? path.resolve(argv[0]) : path.join(root, "docs/plans");
  let files;
  try {
    files = planFiles(dir);
  } catch (err) {
    process.stderr.write(`${dir}: ${err.message}\n`);
    return 1;
  }
  let failed = false;
  for (const file of files) {
    const relative = path.relative(root, file);
    const shown = relative.startsWith("..") ? file : relative;
    process.stdout.write(`${shown}\n`);
    const result = spawnSync(process.execPath, [checker, file], {
      cwd: root,
      encoding: "utf8",
    });
    if (result.stdout) {
      process.stdout.write(result.stdout);
    }
    if (result.stderr) {
      process.stderr.write(result.stderr);
    }
    if (result.error) {
      process.stderr.write(`${result.error.message}\n`);
    }
    if (result.status !== 0) {
      failed = true;
    }
  }
  return failed ? 1 : 0;
}

if (require.main === module) {
  process.exitCode = main();
}
