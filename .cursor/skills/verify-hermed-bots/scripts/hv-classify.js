#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const SKILL_ROOT = path.resolve(__dirname, "..");
const DEFAULT_MAP = path.join(SKILL_ROOT, "features", "map.v1.json");
const DEFAULT_SCHEMA = path.join(SKILL_ROOT, "schema", "dry-run.v1.json");
const REQUIRED_SKILL_FILES = [
  "SKILL.md",
  "features/README.md",
  "features/map.v1.json",
  "schema/dry-run.v1.json",
  "scripts/hv-classify.js",
];
const FULL_VERIFY_LABEL = "needs-full-verify";
const NEEDS_UI_LABEL = "needs-ui";

function usage() {
  return [
    "usage: hv-classify.js --dry-run [--files a,b] [--files-from path] [--feature-map path]",
    "                      [--schema path] [--ui-unavailable] [--same-patch-id] [--pr-pass]",
    "                      [--label name]",
    "       hv-classify.js doctor [--skill-root path]",
  ].join("\n");
}

function escapeRe(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function globToRegExp(glob) {
  const normalized = String(glob).replace(/\\/g, "/");
  let out = "^";
  for (let i = 0; i < normalized.length; ) {
    if (normalized.startsWith("**/", i)) {
      out += "(?:.*/)?";
      i += 3;
      continue;
    }
    if (normalized.startsWith("**", i)) {
      out += ".*";
      i += 2;
      continue;
    }
    const ch = normalized[i];
    if (ch === "*") {
      out += "[^/]*";
    } else if (ch === "?") {
      out += "[^/]";
    } else {
      out += escapeRe(ch);
    }
    i += 1;
  }
  out += "$";
  return new RegExp(out);
}

function matchGlob(file, glob) {
  const normalized = String(file).replace(/\\/g, "/").replace(/^\.\//, "");
  return globToRegExp(glob).test(normalized);
}

function typeOf(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

function validateAgainstSchema(value, schema, pointer = "#") {
  const errors = [];
  if (schema.type && typeOf(value) !== schema.type) {
    errors.push(`${pointer}: type ${schema.type} attendu`);
    return errors;
  }
  if (schema.enum && !schema.enum.includes(value)) {
    errors.push(`${pointer}: valeur hors enum`);
  }
  if (schema.minLength != null && typeof value === "string" && value.length < schema.minLength) {
    errors.push(`${pointer}: trop court`);
  }
  if (schema.type === "object" && value && typeof value === "object") {
    const required = schema.required || [];
    for (const key of required) {
      if (!Object.prototype.hasOwnProperty.call(value, key)) {
        errors.push(`${pointer}: champ requis manquant: ${key}`);
      }
    }
    const properties = schema.properties || {};
    for (const key of Object.keys(value)) {
      if (!Object.prototype.hasOwnProperty.call(properties, key)) {
        if (schema.additionalProperties === false) {
          errors.push(`${pointer}: champ inconnu: ${key}`);
        }
        continue;
      }
      errors.push(...validateAgainstSchema(value[key], properties[key], `${pointer}/${key}`));
    }
  }
  if (schema.type === "array" && Array.isArray(value) && schema.items) {
    value.forEach((item, index) => {
      errors.push(...validateAgainstSchema(item, schema.items, `${pointer}/${index}`));
    });
  }
  return errors;
}

function loadJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function result({ path: classifyPath, needs_ui, features, mode, ok, errors, ui_plan }) {
  return {
    path: classifyPath,
    needs_ui,
    features,
    mode,
    ok,
    errors,
    ui_plan: ui_plan || "none",
  };
}

function printResult(payload, schema, exitOk) {
  const schemaErrors = validateAgainstSchema(payload, schema);
  const out = schemaErrors.length === 0
    ? payload
    : result({
      path: payload.path || "fast",
      needs_ui: Boolean(payload.needs_ui),
      features: Array.isArray(payload.features) ? payload.features : [],
      mode: payload.mode === "light" ? "light" : "full",
      ok: false,
      errors: [...(payload.errors || []), ...schemaErrors.map((err) => `schema: ${err}`)],
      ui_plan: payload.ui_plan === "ui-core" || payload.ui_plan === "ui-full" ? payload.ui_plan : "none",
    });
  process.stdout.write(`${JSON.stringify(out)}\n`);
  return out.ok && exitOk ? 0 : 1;
}

function parseList(value) {
  return String(value)
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function readFilesFrom(file) {
  const raw = file === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(file, "utf8");
  return raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
}

function parseArgs(argv) {
  const opts = {
    doctor: false,
    dryRun: false,
    files: [],
    featureMap: DEFAULT_MAP,
    schema: DEFAULT_SCHEMA,
    skillRoot: SKILL_ROOT,
    uiUnavailable: process.env.HV_UI_UNAVAILABLE === "1" || process.env.HV_UI_AVAILABLE === "0",
    samePatchId: false,
    prPass: false,
    labels: [],
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      return argv[i];
    };
    if (arg === "doctor") {
      opts.doctor = true;
    } else if (arg === "--dry-run") {
      opts.dryRun = true;
    } else if (arg === "--files") {
      opts.files.push(...parseList(next() || ""));
    } else if (arg === "--files-from") {
      opts.files.push(...readFilesFrom(next() || ""));
    } else if (arg === "--feature-map") {
      opts.featureMap = path.resolve(next() || "");
    } else if (arg === "--schema") {
      opts.schema = path.resolve(next() || "");
    } else if (arg === "--skill-root") {
      opts.skillRoot = path.resolve(next() || "");
    } else if (arg === "--ui-unavailable") {
      opts.uiUnavailable = true;
    } else if (arg === "--same-patch-id") {
      opts.samePatchId = true;
    } else if (arg === "--pr-pass") {
      opts.prPass = true;
    } else if (arg === "--label") {
      opts.labels.push(...parseList(next() || ""));
    } else if (arg === "--help" || arg === "-h") {
      opts.help = true;
    } else {
      opts.unknown = arg;
    }
  }
  return opts;
}

function classifyMode(opts) {
  if (opts.labels.includes(FULL_VERIFY_LABEL)) return "full";
  if (opts.samePatchId && opts.prPass) return "light";
  return "full";
}

function pathEntryLabel(feature, featureIndex, entryIndex) {
  const id = feature && typeof feature.id === "string" && feature.id
    ? feature.id
    : `index ${featureIndex}`;
  return `${id}/${entryIndex}`;
}

function validateFeatureMap(parsed) {
  if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.features)) {
    return ["feature map invalide: version 1 requise"];
  }
  const errors = [];
  parsed.features.forEach((feature, featureIndex) => {
    if (feature == null) {
      errors.push(`feature map invalide: fonctionnalité nulle à l'index ${featureIndex}`);
      return;
    }
    if (typeof feature !== "object" || Array.isArray(feature)) {
      errors.push(`feature map invalide: fonctionnalité invalide à l'index ${featureIndex}`);
      return;
    }
    if (typeof feature.id !== "string" || !feature.id) {
      errors.push(`feature map invalide: identifiant manquant à l'index ${featureIndex}`);
    }
    if (!Array.isArray(feature.paths)) {
      errors.push(
        `feature map invalide: paths manquants pour ${feature.id || `index ${featureIndex}`}`,
      );
      return;
    }
    feature.paths.forEach((entry, entryIndex) => {
      const label = pathEntryLabel(feature, featureIndex, entryIndex);
      if (typeof entry === "string") {
        if (!entry) {
          errors.push(`feature map invalide: glob manquant (${label})`);
        }
        return;
      }
      if (entry == null || typeof entry !== "object" || Array.isArray(entry)) {
        errors.push(`feature map invalide: entrée de chemin invalide (${label})`);
        return;
      }
      if (typeof entry.glob !== "string" || !entry.glob) {
        errors.push(`feature map invalide: glob manquant (${label})`);
      }
      if (typeof entry.needs_ui !== "boolean") {
        errors.push(`feature map invalide: needs_ui manquant (${label})`);
      }
      if (entry.ui_plan != null && entry.ui_plan !== "core" && entry.ui_plan !== "full") {
        errors.push(`feature map invalide: ui_plan invalide (${label})`);
      }
    });
  });
  return errors;
}

function loadFeatureMap(mapPath) {
  if (!fs.existsSync(mapPath)) {
    return { error: `feature map absente: ${path.basename(mapPath)}` };
  }
  let parsed;
  try {
    parsed = loadJson(mapPath);
  } catch {
    return { error: `feature map illisible: ${path.basename(mapPath)}` };
  }
  const errors = validateFeatureMap(parsed);
  if (errors.length > 0) {
    return { error: errors[0], errors };
  }
  return { map: parsed };
}

const UI_CORE_ONLY_TESTING = [
  "HermedBotsUITests/SixActions",
  "HermedBotsUITests/LaunchTests",
  "HermedBotsUITests/HD12Video",
];

function isInterfaceSwift(file) {
  const normalized = String(file).replace(/\\/g, "/").replace(/^\.\//, "");
  return /^HermedBots\/.+\.swift$/.test(normalized) && !normalized.startsWith("HermedBots/Secrets/");
}

function mappedUiPlan(file, map) {
  for (const feature of map.features) {
    for (const entry of feature.paths) {
      const glob = typeof entry === "string" ? entry : entry.glob;
      if (!matchGlob(file, glob)) continue;
      if (typeof entry !== "object" || entry == null) continue;
      if (entry.ui_plan === "full") return "ui-full";
      if (entry.ui_plan === "core") return "ui-core";
    }
  }
  return null;
}

function selectUiPlan(files, map, needsUi) {
  if (!needsUi) return "none";
  let sawFull = false;
  let sawCore = false;
  for (const file of files) {
    if (isInterfaceSwift(file)) sawFull = true;
    const plan = mappedUiPlan(file, map);
    if (plan === "ui-full") sawFull = true;
    if (plan === "ui-core") sawCore = true;
  }
  if (sawFull) return "ui-full";
  if (sawCore) return "ui-core";
  return "ui-full";
}

function onlyTestingArgs(plan) {
  if (plan !== "ui-core") return [];
  return UI_CORE_ONLY_TESTING.map((id) => `-only-testing:${id}`);
}

function classifyFiles(files, map) {
  const matched = new Set();
  let needsUi = false;
  for (const file of files) {
    if (isInterfaceSwift(file)) needsUi = true;
    for (const feature of map.features) {
      const paths = feature.paths;
      for (const entry of paths) {
        const glob = typeof entry === "string" ? entry : entry.glob;
        const entryNeedsUi = typeof entry === "string" ? Boolean(feature.needs_ui) : Boolean(entry.needs_ui);
        if (!matchGlob(file, glob)) continue;
        matched.add(feature.id);
        if (entryNeedsUi) needsUi = true;
      }
    }
  }
  return {
    features: [...matched].sort(),
    needs_ui: needsUi,
    ui_plan: selectUiPlan(files, map, needsUi),
  };
}

function classify(opts) {
  const mode = classifyMode(opts);
  const forceUi = opts.labels.includes(NEEDS_UI_LABEL);
  const failed = (errors) => result({
    path: "ui",
    needs_ui: true,
    features: [],
    mode,
    ok: false,
    errors,
    ui_plan: "ui-full",
  });
  try {
    const loaded = loadFeatureMap(opts.featureMap);
    if (loaded.error) {
      return failed(loaded.errors || [loaded.error]);
    }
    const hit = classifyFiles(opts.files, loaded.map);
    const needsUi = hit.needs_ui || forceUi;
    let classifyPath = "fast";
    if (needsUi) classifyPath = opts.uiUnavailable ? "fast_suspended" : "ui";
    return result({
      path: classifyPath,
      needs_ui: needsUi,
      features: hit.features,
      mode,
      ok: true,
      errors: [],
      ui_plan: classifyPath === "fast" ? "none" : selectUiPlan(opts.files, loaded.map, needsUi),
    });
  } catch (err) {
    return failed([`classement impossible: ${err && err.message ? err.message : err}`]);
  }
}

function doctor(skillRoot) {
  const missing = REQUIRED_SKILL_FILES.filter((rel) => !fs.existsSync(path.join(skillRoot, rel)));
  if (missing.length === 0) {
    process.stdout.write(`${JSON.stringify({ ok: true, missing: [] })}\n`);
    return 0;
  }
  process.stdout.write(`${JSON.stringify({ ok: false, missing })}\n`);
  return 1;
}

function main(argv = process.argv.slice(2)) {
  const opts = parseArgs(argv);
  if (opts.help) {
    process.stderr.write(`${usage()}\n`);
    return 0;
  }
  if (opts.unknown) {
    process.stderr.write(`${usage()}\n`);
    return 2;
  }
  if (opts.doctor) {
    return doctor(opts.skillRoot);
  }
  if (!opts.dryRun) {
    process.stderr.write(`${usage()}\n`);
    return 2;
  }
  let schema;
  try {
    schema = loadJson(opts.schema);
  } catch {
    process.stderr.write("schema dry-run v1 illisible\n");
    return 1;
  }
  try {
    return printResult(classify(opts), schema, true);
  } catch (err) {
    return printResult(result({
      path: "ui",
      needs_ui: true,
      features: [],
      mode: "full",
      ok: false,
      errors: [`classement impossible: ${err && err.message ? err.message : err}`],
      ui_plan: "ui-full",
    }), schema, false);
  }
}

module.exports = {
  classify,
  classifyFiles,
  classifyMode,
  selectUiPlan,
  onlyTestingArgs,
  isInterfaceSwift,
  UI_CORE_ONLY_TESTING,
  doctor,
  globToRegExp,
  loadFeatureMap,
  matchGlob,
  parseArgs,
  validateAgainstSchema,
  validateFeatureMap,
  main,
  REQUIRED_SKILL_FILES,
  DEFAULT_MAP,
  DEFAULT_SCHEMA,
  SKILL_ROOT,
  FULL_VERIFY_LABEL,
  NEEDS_UI_LABEL,
};

if (require.main === module) {
  process.exitCode = main();
}
