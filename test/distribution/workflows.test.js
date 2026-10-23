"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(root, file), "utf8");
const release = read(".github/workflows/release.yml");
const freeze = read(".github/workflows/freeze-version.yml");
const publish = read("scripts/publish-distribution.sh");

test("freeze installs zsh before npm test: the runner-publish tests spawn it and ubuntu has none", () => {
  const install = freeze.indexOf("apt-get install");
  assert.ok(install > 0, "freeze-version.yml must install zsh");
  assert.match(freeze.slice(install, install + 80), /zsh/);
  assert.ok(install < freeze.indexOf("run: npm test"));
});

test("an operator can freeze the current VERSION on main without bumping it, and nowhere else", () => {
  assert.match(freeze, /on:\n  push:\n    branches: \[main\]\n    paths: \[VERSION\]\n  workflow_dispatch:\n/);
  assert.match(freeze, /  tag:\n    if: github\.ref == 'refs\/heads\/main'\n/);
});

test("the macOS job leaves the test suite to Freeze and CI: its fake-server tests hang on the hosted image", () => {
  const job = release.slice(release.indexOf("  release:"));
  assert.ok(!job.includes("npm test"));
  assert.match(job, /run: npm run lint/);
});

test("release builds on the runner image that ships macOS 27 and Xcode 27", () => {
  const job = release.slice(release.indexOf("  release:"));
  assert.match(job, /runs-on: xcode-27\n/);
  assert.ok(!release.includes("macos-latest"));
});

test("release never selects a beta Xcode, including a stable-looking symlink to one", () => {
  assert.match(release, /os\.path\.realpath/);
  assert.match(release, /'beta' in/);
});

test("release checks that the Homebrew tap is public and writable before signing", () => {
  const verify = release.slice(release.indexOf("Verify tag"), release.indexOf("npm ci"));
  assert.match(verify, /tap=\$\(node scripts\/distribution\.js tap "\$DISTRIBUTION_REPOSITORY"\)/);
  assert.match(verify, /repos\/\$tap" --jq \.visibility\)" = public/);
  assert.match(verify, /repos\/\$tap" --jq \.permissions\.push\)" = true/);
});

test("a rehearsal signs and notarizes the dispatched branch but publishes nothing", () => {
  assert.match(release, /rehearsal:\n\s+description:.*\n\s+type: boolean\n\s+default: false/);
  assert.match(release, /ref: \$\{\{ inputs\.rehearsal && github\.sha \|\| inputs\.tag \|\| github\.ref_name \}\}/);
  assert.match(release, /if: \$\{\{ !inputs\.rehearsal \}\}\n\s+run: git merge-base --is-ancestor HEAD origin\/main/);
  const step = release.slice(release.indexOf("- name: Publish archives"));
  assert.match(step.split("run:")[0], /if: \$\{\{ !inputs\.rehearsal \}\}/);
});

test("the cask goes to the tap, never to the releases repository", () => {
  assert.match(publish, /tap=\$\(node scripts\/distribution\.js tap "\$DISTRIBUTION_REPOSITORY"\)/);
  assert.match(publish, /path="repos\/\$tap\/contents\/Casks\/hermed-bots\.rb"/);
  assert.ok(!publish.includes('path="repos/$DISTRIBUTION_REPOSITORY'));
});

test("a rehearsal cannot publish and the workflow makes no write call to another repository", () => {
  const steps = release.split("\n      - ");
  const publishing = steps.filter(step => step.includes("publish-distribution.sh"));
  assert.equal(publishing.length, 1);
  assert.match(publishing[0].split("run:")[0], /if: \$\{\{ !inputs\.rehearsal \}\}/);
  for (const line of release.split("\n").filter(text => text.includes("gh api"))) {
    assert.doesNotMatch(line, / (-[fFX]|--method|--input|--field|--raw-field)( |$)/);
  }
  assert.doesNotMatch(release, /gh (release|pr|repo|workflow)|git push/);
});

test("a rehearsal needs the full configuration and the run states which stages ran", () => {
  const preflight = release.slice(release.indexOf("  preflight:"), release.indexOf("  release:"));
  assert.match(preflight, /REHEARSAL: \$\{\{ inputs\.rehearsal \}\}\n[\s\S]*run: node scripts\/distribution\.js preflight/);
  const job = release.slice(release.indexOf("  release:"));
  assert.match(job, /\n    env:\n      RELEASE_TAG: .*\n      REHEARSAL: \$\{\{ inputs\.rehearsal \}\}\n/);
  const proof = job.slice(job.indexOf("- name: Summarize the rehearsal proof"));
  // shell: bash adds pipefail, so a failed proof is not hidden by the tee that feeds the step summary
  assert.match(proof.split("run:")[0], /if: \$\{\{ always\(\) && inputs\.rehearsal \}\}\n\s+shell: bash\n/);
  assert.match(proof.split("\n      - ")[0], /run: node scripts\/distribution\.js proof \.audit\/distribution\/stages\.txt .*GITHUB_STEP_SUMMARY/);
  assert.match(job, /\.audit\/distribution\/stages\.txt/);
});
