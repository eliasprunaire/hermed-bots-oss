"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

const CI = read(".github/workflows/ci.yml");
const PERF = read(".github/workflows/perf.yml");
const SCHEME = read(
  "HermedBots.xcodeproj/xcshareddata/xcschemes/HermedBots.xcscheme",
);
const DOCS = read("docs/perf-probes.md");

const PROBES = [
  "ApprovalPerfProbe",
  "BannerPerfProbe",
  "BotsPerfProbe",
  "ColdLaunchProbe",
  "ConversationPerfProbe",
  "ModelPerfProbe",
];

const PERF_METHODS = [
  "ConcurrencyTests/testPerfFiveHolds",
  "ConcurrencyTests/testPerfOneHold",
  "KillSwitchTests/testPerfFiveStops",
  "LaunchTests/testColdLaunchToVersionVisibleStaysUnderTwoSeconds",
];

function skippedIdentifiers(xml) {
  const block = xml.slice(xml.indexOf("<SkippedTests>"), xml.indexOf("</SkippedTests>"));
  return [...block.matchAll(/Identifier = "([^"]+)"/g)].map((match) => match[1]);
}

test("the pull request Swift job skips PerfTests", () => {
  const job = CI.slice(CI.indexOf("  swift-test:"));
  assert.match(job, /run: swift test --package-path Packages\/HermesAdapter --skip PerfTests\n/);
  assert.doesNotMatch(job, /run: swift test --package-path Packages\/HermesAdapter\n/);
});

test("the pull request workflow still runs npm test", () => {
  assert.match(CI, /on:\n  pull_request:/);
  assert.match(CI, /run: npm test\n/);
});

test("the dedicated perf workflow is never a pull request job", () => {
  assert.doesNotMatch(PERF, /pull_request/);
  assert.match(PERF, /workflow_dispatch:/);
  assert.match(PERF, /schedule:\n    - cron: "17 4 \* \* 1"/);
  assert.match(PERF, /push:\n    branches: \[main\]/);
  assert.match(
    PERF,
    /run: swift test --package-path Packages\/HermesAdapter --filter PerfTests\n/,
  );
});

test("the HermedBots scheme skips every UI probe class and perf method", () => {
  const skipped = skippedIdentifiers(SCHEME);
  for (const id of [...PROBES, ...PERF_METHODS]) {
    assert.ok(skipped.includes(id), `missing skip ${id}`);
  }
  for (const functional of ["SixActions", "LaunchTests", "Compat", "Errors"]) {
    assert.ok(!skipped.includes(functional), `functional class ${functional} is skipped`);
  }
});

test("the how-to names both the skip and the filter", () => {
  assert.match(DOCS, /--skip PerfTests/);
  assert.match(DOCS, /--filter PerfTests/);
  assert.match(DOCS, /-only-testing:HermedBotsUITests\/ColdLaunchProbe/);
  for (const id of PROBES) {
    assert.match(DOCS, new RegExp(id));
  }
  assert.match(DOCS, /LaunchTests\/testColdLaunchToVersionVisibleStaysUnderTwoSeconds/);
});
