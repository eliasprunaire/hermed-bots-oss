"use strict";

const { spawnSync } = require("node:child_process");
const { mkdirSync, mkdtempSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const {
  checkSources,
  explicitSquashBody,
} = require("./check-pr-attribution.js");

const TRUSTED_HELPERS = [
  ["scripts/squash-merge.js", "squash-merge.js"],
  ["scripts/check-pr-attribution.js", "check-pr-attribution.js"],
];

function materializeTrustedHelpers(rev, dest, deps = {}) {
  mkdirSync(dest, { recursive: true });
  for (const [gitPath, name] of TRUSTED_HELPERS) {
    const result = spawnSync("git", ["show", `${rev}:${gitPath}`], {
      cwd: deps.cwd,
      encoding: "utf8",
    });
    if (result.status !== 0) {
      const detail = (result.stderr || "").trim();
      throw new Error(detail || `missing ${gitPath} at ${rev}`);
    }
    writeFileSync(join(dest, name), result.stdout);
  }
  return join(dest, "squash-merge.js");
}

function parseArgs(argv) {
  const usage = "usage: squash-merge.js <pr> [--auto]";
  let pr = null;
  let auto = false;
  for (const arg of argv) {
    if (arg === "--auto") {
      auto = true;
      continue;
    }
    if (arg.startsWith("-")) {
      return { error: usage };
    }
    if (pr != null) {
      return { error: usage };
    }
    pr = arg;
  }
  if (pr == null || pr === "") {
    return { error: usage };
  }
  return { pr, auto };
}

function mergeArgv(pr, bodyFile, forge, auto = false) {
  const bin = forge === "origin" ? "origin" : "gh";
  const command = [
    bin,
    "pr",
    "merge",
    String(pr),
    "--squash",
    "--body-file",
    bodyFile,
  ];
  if (auto) {
    command.push("--auto");
  }
  return command;
}

function defaultResolveForge() {
  const which = spawnSync("which", ["origin"], { encoding: "utf8" });
  if (which.status !== 0) {
    return "gh";
  }
  const probe = spawnSync("origin", ["repo", "view", "--json", "name"], {
    encoding: "utf8",
  });
  if (probe.status === 0) {
    return "origin";
  }
  return "gh";
}

function main(argv = process.argv.slice(2), deps = {}) {
  const parsed = parseArgs(argv);
  if (parsed.error) {
    console.error(parsed.error);
    return 1;
  }
  const pr = parsed.pr;
  const squashBody = (deps.squashBody || explicitSquashBody)();
  const failures = checkSources([{ label: "squash body", text: squashBody }]);
  if (failures.length > 0) {
    for (const line of failures) {
      console.error(line);
    }
    return 1;
  }
  const dir = mkdtempSync(join(tmpdir(), "squash-"));
  const bodyFile = join(dir, "body.txt");
  writeFileSync(bodyFile, squashBody);
  const forge = (deps.resolveForge || defaultResolveForge)();
  const command = mergeArgv(pr, bodyFile, forge, parsed.auto);
  const spawn =
    deps.spawn ||
    ((cmd) => {
      const [bin, ...args] = cmd;
      const result = spawnSync(bin, args, { stdio: "inherit" });
      return result.status ?? 1;
    });
  return spawn(command);
}

module.exports = { materializeTrustedHelpers, mergeArgv, parseArgs, main };

if (require.main === module) {
  process.exitCode = main();
}
