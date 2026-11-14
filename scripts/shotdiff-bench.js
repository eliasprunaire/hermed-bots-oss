"use strict";

const {
  chmodSync,
  copyFileSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const {
  ROOT,
  SHOTDIFF,
  shotdiffIhdrEnv,
  runShotdiff,
  writePair,
  synthetic1280x800,
} = require("../test/shotdiff-harness.js");

const REPS = 3;
const MAIN_SCRIPT = join(ROOT, "test/fixtures/shotdiff/hv-shotdiff-main.sh");

function extractMainScript(dir) {
  const path = join(dir, "hv-shotdiff-main.sh");
  copyFileSync(MAIN_SCRIPT, path);
  chmodSync(path, 0o755);
  return path;
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  if (sorted.length % 2) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

function formatSecs(values) {
  return values.map((v) => v.toFixed(3)).join(" ");
}

function timePair(script, spec, parent) {
  const dir = mkdtempSync(join(parent, "run-"));
  const pair = writePair(dir, spec.name, spec.base, spec.cap);
  const env = shotdiffIhdrEnv(dir, spec.ae);
  const t0 = process.hrtime.bigint();
  const run = runShotdiff(script, pair.cap, pair.base, pair.dif, env);
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  if (run.status !== 0 && run.status !== 11) {
    throw new Error(`shotdiff rc=${run.status} err=${run.stderr} out=${run.stdout}`);
  }
  return { ms, status: run.status, stdout: run.stdout.trim() };
}

function benchOne(label, spec, mainScript, parent) {
  const before = [];
  const after = [];
  let sampleOut = "";
  for (let i = 0; i < REPS; i++) {
    const a = timePair(mainScript, spec, parent);
    const b = timePair(SHOTDIFF, spec, parent);
    before.push(a.ms / 1000);
    after.push(b.ms / 1000);
    sampleOut = b.stdout;
  }
  const medB = median(before);
  const medA = median(after);
  const speedup = medB / medA;
  process.stdout.write(`paire ${label}\n`);
  process.stdout.write(`  avant (main)  ${formatSecs(before)}  médiane ${medB.toFixed(3)} s/paire\n`);
  process.stdout.write(`  après (tête)  ${formatSecs(after)}  médiane ${medA.toFixed(3)} s/paire\n`);
  process.stdout.write(`  accélération médiane ${speedup.toFixed(2)}×  (sortie ${sampleOut})\n`);
  return { before, after, medB, medA, speedup };
}

function hd09Pair() {
  const base = readFileSync(
    join(ROOT, ".cursor/skills/verify-hermed-bots/baselines/hd09-cancelled.png"),
  );
  const cap = readFileSync(join(ROOT, "test/fixtures/shotdiff/hd09-cancelled-c4138edb.png"));
  return { name: "hd09-cancelled.png", ae: "428", base, cap };
}

function main() {
  const parent = mkdtempSync(join(tmpdir(), "hv-shotdiff-bench-"));
  try {
    const mainScript = extractMainScript(parent);
    process.stdout.write(`banc hv-shotdiff : ${REPS} répétitions, même machine\n`);
    benchOne("1280x800 synthétique (écart franc localisé)", synthetic1280x800(), mainScript, parent);
    benchOne("fixture hd09-cancelled (RGBA réelle)", hd09Pair(), mainScript, parent);
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}

if (require.main === module) {
  main();
}

module.exports = { main, median, extractMainScript };
