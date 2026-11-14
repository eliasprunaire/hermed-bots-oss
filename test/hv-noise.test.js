"use strict";

const assert = require("node:assert/strict");
const { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const {
  blitRgb,
  encodePngRgb,
  rgbCanvas,
  shotdiffIhdrEnv,
} = require("./shotdiff-harness.js");
const noise = require("../.cursor/skills/verify-hermed-bots/scripts/hv-noise.js");

const ROOT = join(__dirname, "..");
const HV_NOISE = join(ROOT, ".cursor/skills/verify-hermed-bots/scripts/hv-noise.js");
const FIXTURES = join(__dirname, "fixtures/noise");
const RED = [200, 30, 30];
const GRAY = [121, 121, 121];
const ORANGE = [255, 141, 40];
const BG = [240, 240, 240];

function writeNoisePair(dir) {
  const passA = join(dir, "pass-a");
  const passB = join(dir, "pass-b");
  mkdirSync(passA, { recursive: true });
  mkdirSync(passB, { recursive: true });

  const ident = rgbCanvas(8, 8, [40, 80, 120]);
  writeFileSync(join(passA, "ident.png"), encodePngRgb(8, 8, ident));
  writeFileSync(join(passB, "ident.png"), encodePngRgb(8, 8, ident));

  const shiftA = rgbCanvas(16, 10, BG);
  const shiftB = rgbCanvas(16, 10, BG);
  blitRgb(shiftA, 16, 2, 3, 4, 4, RED);
  blitRgb(shiftB, 16, 4, 3, 4, 4, RED);
  writeFileSync(join(passA, "shift.png"), encodePngRgb(16, 10, shiftA));
  writeFileSync(join(passB, "shift.png"), encodePngRgb(16, 10, shiftB));

  const localA = rgbCanvas(32, 32, BG);
  const localB = rgbCanvas(32, 32, BG);
  blitRgb(localA, 32, 8, 8, 10, 10, ORANGE);
  blitRgb(localB, 32, 8, 8, 10, 10, GRAY);
  writeFileSync(join(passA, "local.png"), encodePngRgb(32, 32, localA));
  writeFileSync(join(passB, "local.png"), encodePngRgb(32, 32, localB));

  writeFileSync(join(passA, "only-a.png"), encodePngRgb(4, 4, rgbCanvas(4, 4, RED)));
  writeFileSync(join(passB, "only-b.png"), encodePngRgb(4, 4, rgbCanvas(4, 4, GRAY)));
  return { passA, passB };
}

function captureIo(env) {
  let out = "";
  let err = "";
  return {
    stdout: {
      write(chunk) {
        out += chunk;
        return true;
      },
    },
    stderr: {
      write(chunk) {
        err += chunk;
        return true;
      },
    },
    env,
    stdoutText() {
      return out;
    },
    stderrText() {
      return err;
    },
  };
}

function noiseEnv(dir) {
  const env = shotdiffIhdrEnv(dir, "0");
  writeFileSync(
    join(dir, "bin", "compare"),
    [
      "#!/bin/sh",
      "a=; b=",
      'for x in "$@"; do',
      '  case "$x" in',
      "    *.png)",
      '      if [ -z "$a" ]; then a=$x; else b=$x; fi',
      "      ;;",
      "  esac",
      "done",
      'if [ -n "$a" ] && [ -n "$b" ] && cmp -s "$a" "$b"; then',
      "  printf '0\\n' >&2",
      "  exit 0",
      "fi",
      "printf '999999\\n' >&2",
      "exit 1",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  return env;
}

test("hv-noise --help décrit la mesure et le verdict shotdiff", () => {
  const io = captureIo(process.env);
  const rc = noise.main(["--help"], io);
  assert.equal(rc, 0);
  assert.match(io.stdoutText(), /passe-1/);
  assert.match(io.stdoutText(), /x,y,lxh/);
  assert.match(io.stdoutText(), /hv-shotdiff/);
});

test("usage incomplet rend 2", () => {
  const io = captureIo(process.env);
  assert.equal(noise.main([], io), 2);
  assert.match(io.stderrText(), /usage:/);
});

test("deux dossiers vides rendent 15", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-noise-empty-"));
  try {
    mkdirSync(join(dir, "a"));
    mkdirSync(join(dir, "b"));
    const io = captureIo(process.env);
    assert.equal(noise.main([join(dir, "a"), join(dir, "b")], io), 15);
    assert.match(io.stderrText(), /SHOT FAIL \(15\)/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("paire identique : zéro pixel, décal 0, verdict OK", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-noise-ident-"));
  try {
    const { passA, passB } = writeNoisePair(dir);
    const measured = noise.measurePair(join(passA, "ident.png"), join(passB, "ident.png"));
    assert.equal(measured.px, 0);
    assert.equal(measured.dist, 0);
    assert.equal(measured.bbox, null);
    assert.equal(measured.shift, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("image décalée de 2 px : décal 2", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-noise-shift-"));
  try {
    const { passA, passB } = writeNoisePair(dir);
    const measured = noise.measurePair(join(passA, "shift.png"), join(passB, "shift.png"));
    assert.ok(measured.px > 0);
    assert.equal(measured.shift, 2);
    assert.equal(measured.dx, 2);
    assert.equal(measured.dy, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("écart franc localisé : boîte 8,8,10x10 et décal 0", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-noise-local-"));
  try {
    const { passA, passB } = writeNoisePair(dir);
    const measured = noise.measurePair(join(passA, "local.png"), join(passB, "local.png"));
    assert.equal(measured.px, 100);
    assert.equal(measured.bbox, "8,8,10x10");
    assert.equal(measured.shift, 0);
    assert.ok(measured.dist > 20);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("CLI : décal, boîte, verdict shotdiff et écrans d'un seul côté", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-noise-cli-"));
  try {
    const { passA, passB } = writeNoisePair(dir);
    const env = noiseEnv(dir);
    const io = captureIo(env);
    const beforeA = readdirSync(passA).sort().join(",");
    const beforeB = readdirSync(passB).sort().join(",");
    const stampA = statSync(join(passA, "ident.png")).mtimeMs;
    const rc = noise.main([passA, passB], io);
    assert.equal(rc, 0, io.stderrText());
    const out = io.stdoutText();
    assert.match(out, /ident\.png\s+0\s+0\.0\s+-\s+0\s+OK/);
    assert.match(out, /shift\.png\s+\d+\s+\d+\.\d+\s+\S+\s+2\s+DIFF/);
    assert.match(out, /local\.png\s+100\s+\d+\.\d+\s+8,8,10x10\s+0\s+DIFF/);
    assert.match(out, /Présents seulement dans passe-1 : only-a\.png/);
    assert.match(out, /Présents seulement dans passe-2 : only-b\.png/);
    assert.equal(readdirSync(passA).sort().join(","), beforeA);
    assert.equal(readdirSync(passB).sort().join(","), beforeB);
    assert.equal(statSync(join(passA, "ident.png")).mtimeMs, stampA);
    assert.equal(readdirSync(passA).includes("dif"), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("CLI --json résume décal, boîte et verdict", () => {
  const dir = mkdtempSync(join(tmpdir(), "hv-noise-json-"));
  try {
    const { passA, passB } = writeNoisePair(dir);
    const io = captureIo(noiseEnv(dir));
    const rc = noise.main(["--json", passA, passB], io);
    assert.equal(rc, 0, io.stderrText());
    const payload = JSON.parse(io.stdoutText());
    assert.equal(payload.tolerance, 0.02);
    assert.equal(payload.fuzz, 0.05);
    assert.equal(payload.maxShift, 4);
    const byName = Object.fromEntries(payload.screens.map((row) => [row.name, row]));
    assert.equal(byName["ident.png"].verdict, "OK");
    assert.equal(byName["ident.png"].shift, 0);
    assert.equal(byName["ident.png"].bbox, null);
    assert.equal(byName["shift.png"].shift, 2);
    assert.equal(byName["shift.png"].verdict, "DIFF");
    assert.equal(byName["local.png"].bbox, "8,8,10x10");
    assert.equal(byName["local.png"].verdict, "DIFF");
    assert.deepEqual(payload.only1, ["only-a.png"]);
    assert.deepEqual(payload.only2, ["only-b.png"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("fixtures versionnées : mêmes décal, boîte et verdict", () => {
  const passA = join(FIXTURES, "pass-a");
  const passB = join(FIXTURES, "pass-b");
  const dir = mkdtempSync(join(tmpdir(), "hv-noise-fix-"));
  try {
    const io = captureIo(noiseEnv(dir));
    const rc = noise.main(["--json", passA, passB], io);
    assert.equal(rc, 0, io.stderrText());
    const payload = JSON.parse(io.stdoutText());
    const byName = Object.fromEntries(payload.screens.map((row) => [row.name, row]));
    assert.equal(byName["ident.png"].verdict, "OK");
    assert.equal(byName["shift.png"].shift, 2);
    assert.equal(byName["local.png"].bbox, "8,8,10x10");
    assert.equal(byName["local.png"].verdict, "DIFF");
    assert.deepEqual(payload.only1, ["only-a.png"]);
    assert.deepEqual(payload.only2, ["only-b.png"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("le script appelle hv-shotdiff.sh sans promotion ni réseau", () => {
  const src = readFileSync(HV_NOISE, "utf8");
  assert.match(src, /hv-shotdiff\.sh/);
  assert.doesNotMatch(src, /spawnSync\([^)]*bless/);
  assert.doesNotMatch(src, /https?:\/\//);
});
