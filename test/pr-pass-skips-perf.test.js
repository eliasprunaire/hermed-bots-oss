"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const uiDir = path.join(root, "HermedBotsUITests");

const CI = read(".github/workflows/ci.yml");
const PERF = read(".github/workflows/perf.yml");
const SCHEME = read(
  "HermedBots.xcodeproj/xcshareddata/xcschemes/HermedBots.xcscheme",
);
const PERF_SCHEME = read(
  "HermedBots.xcodeproj/xcshareddata/xcschemes/HermedBotsPerf.xcscheme",
);
const DOCS = read("docs/perf-probes.md");

function skippedIdentifiers(xml) {
  const start = xml.indexOf("<SkippedTests>");
  if (start === -1) {
    return [];
  }
  const block = xml.slice(start, xml.indexOf("</SkippedTests>"));
  return [...block.matchAll(/Identifier = "([^"]+)"/g)].map((match) => match[1]);
}

function uiProbeClasses() {
  return fs
    .readdirSync(uiDir)
    .filter((name) => name.endsWith("PerfProbe.swift") || name === "ColdLaunchProbe.swift")
    .map((name) => name.replace(/\.swift$/, ""))
    .sort();
}

function budgetMethods() {
  const found = [];
  for (const name of fs.readdirSync(uiDir).filter((file) => file.endsWith(".swift"))) {
    const text = fs.readFileSync(path.join(uiDir, name), "utf8");
    const className = name.replace(/\.swift$/, "");
    for (const match of text.matchAll(/func (testPerf\w+|testColdLaunchToVersionVisibleStaysUnderTwoSeconds|testResumeBudget)\(/g)) {
      found.push(`${className}/${match[1]}`);
    }
  }
  return found.sort();
}

test("the pull request Swift job skips PerfTests", () => {
  const job = CI.slice(CI.indexOf("  swift-test:"));
  assert.match(job, /--skip PerfTests/);
  assert.doesNotMatch(job, /run: swift test --package-path Packages\/HermesAdapter\n/);
});

test("the pull request workflow still runs npm test", () => {
  assert.match(CI, /\bpull_request:/);
  assert.match(CI, /run: npm test\n/);
});

test("the dedicated perf workflow is never a pull request job", () => {
  assert.doesNotMatch(PERF, /\bpull_request:/);
  assert.match(PERF, /\bworkflow_dispatch:/);
  assert.match(PERF, /\bschedule:/);
  assert.match(PERF, /\bpush:/);
  assert.match(PERF, /branches: \[main\]/);
  assert.match(PERF, /--filter PerfTests/);
  const ciImage = CI.match(/container: (swift:\S+)/);
  assert.ok(ciImage, "CI names a Swift container");
  assert.match(PERF, new RegExp(`container: ${ciImage[1]}\\b`));
});

test("the HermedBots scheme skips every UI probe class and budget method from source", () => {
  const skipped = skippedIdentifiers(SCHEME);
  const probes = uiProbeClasses();
  assert.ok(probes.length > 0, "no UI probe classes on disk");
  for (const id of probes) {
    assert.ok(skipped.includes(id), `missing skip ${id}`);
  }
  for (const id of budgetMethods()) {
    assert.ok(skipped.includes(id), `missing skip ${id}`);
  }
  for (const functional of ["SixActions", "LaunchTests", "Compat", "Errors"]) {
    assert.ok(!skipped.includes(functional), `functional class ${functional} is skipped`);
  }
});

test("HermedBotsPerf does not skip those classes, so a dedicated run can start them", () => {
  assert.equal(skippedIdentifiers(PERF_SCHEME).length, 0);
  assert.match(PERF_SCHEME, /BlueprintName = "HermedBotsUITests"/);
});

test("the how-to names both the skip and the dedicated scheme", () => {
  assert.match(DOCS, /--skip PerfTests/);
  assert.match(DOCS, /--filter PerfTests/);
  assert.match(DOCS, /-scheme HermedBotsPerf/);
  assert.match(DOCS, /-only-testing:HermedBotsUITests\/ColdLaunchProbe/);
  for (const id of uiProbeClasses()) {
    assert.match(DOCS, new RegExp(id));
  }
});
