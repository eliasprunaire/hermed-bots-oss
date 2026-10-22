"use strict";

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const root = path.resolve(__dirname, "..");

function trackedJs() {
  const listed = spawnSync("git", ["ls-files", "-z", "*.js"], {
    cwd: root,
    encoding: "buffer",
  });
  if (listed.error) {
    throw listed.error;
  }
  if (listed.status !== 0) {
    const errText = listed.stderr && listed.stderr.length
      ? listed.stderr
      : Buffer.from("git ls-files failed\n");
    process.stderr.write(errText);
    process.exit(listed.status || 1);
  }
  return listed.stdout.toString("utf8").split("\0").filter(Boolean);
}

function checkFile(file) {
  const result = spawnSync(process.execPath, ["--check", file], {
    cwd: root,
    encoding: "utf8",
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status === 0) {
    return true;
  }
  if (result.stderr) {
    process.stderr.write(result.stderr);
  }
  if (result.stdout) {
    process.stderr.write(result.stdout);
  }
  return false;
}

function main(argv = process.argv.slice(2)) {
  const files = argv.length > 0 ? argv : trackedJs();
  let failed = false;
  for (const file of files) {
    if (!checkFile(file)) {
      failed = true;
    }
  }
  return failed ? 1 : 0;
}

if (require.main === module) {
  process.exitCode = main();
}
