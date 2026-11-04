"use strict";

const assert = require("node:assert/strict");
const { mkdtempSync, readFileSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const { main } = require("../scripts/check-pr-attribution.js");

const ROOT = join(__dirname, "..");

function loadConfig() {
  return JSON.parse(readFileSync(join(ROOT, "renovate.json"), "utf8"));
}

function expandTripleStache(template, values) {
  return String(template).replace(/\{\{\{([A-Za-z]+)\}\}\}/g, (_, key) => {
    return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : "";
  });
}

function runMain(argv) {
  const error = console.error;
  const chunks = [];
  console.error = (...args) => {
    chunks.push(args.map(String).join(" "));
  };
  try {
    return { code: main(argv), err: chunks.join("\n") };
  } finally {
    console.error = error;
  }
}

test("renovate keeps automerge off and writes French titles and bodies", () => {
  const config = loadConfig();
  assert.equal(config.automerge, false);
  assert.equal(config.semanticCommits, "enabled");
  assert.equal(config.commitMessageAction, "mettre à jour");
  assert.match(config.commitMessageExtra, /^vers /);
  assert.match(config.prBodyTemplate, /^## Pourquoi/m);
  assert.match(config.prBodyTemplate, /^## Ce qui change/m);
  assert.match(config.prBodyTemplate, /^## Périmètre/m);
  assert.match(config.prBodyTemplate, /^## Impact possible/m);
  assert.match(config.prBodyTemplate, /^## Vérification/m);
  assert.match(config.prFooter, /Fusionnez-la manuellement/);
  const topics = (config.packageRules || []).map((rule) => rule.commitMessageTopic);
  assert.equal(topics.some((topic) => /l'action/.test(topic)), true);
  assert.equal(topics.some((topic) => /la dépendance/.test(topic)), true);
  assert.equal(topics.some((topic) => /le paquet Swift/.test(topic)), true);
});

test("the configured Renovate PR body and commit pass pr-attribution", () => {
  const config = loadConfig();
  const table = [
    "| Paquet | Type | Mise à jour | Changement |",
    "|---|---|---|---|",
    "| actions/checkout | action | major | `v4` → `v7` |",
  ].join("\n");
  const body = expandTripleStache(config.prBodyTemplate, {
    table,
    warnings: "",
    notes: "",
    changelogs: "",
    configDescription: "",
    controls: "",
    footer: config.prFooter,
  });
  assert.match(body, /## Pourquoi/);
  assert.doesNotMatch(body, /This PR contains/);
  assert.doesNotMatch(body, /Co-authored-by/);
  const commit = "chore(deps): mettre à jour l'action actions/checkout vers v7\n";
  const dir = mkdtempSync(join(tmpdir(), "renovate-attr-"));
  const bodyFile = join(dir, "body.txt");
  const commitsFile = join(dir, "commits.txt");
  writeFileSync(bodyFile, `${body}\n`);
  writeFileSync(commitsFile, commit);
  const missingAuthor = runMain([
    "--body-file",
    bodyFile,
    "--commits-file",
    commitsFile,
  ]);
  assert.equal(missingAuthor.code, 1);
  assert.match(missingAuthor.err, /## Agents/);
  assert.equal(
    main([
      "--body-file",
      bodyFile,
      "--commits-file",
      commitsFile,
      "--author",
      "renovate[bot]",
    ]),
    0,
  );
});
