#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const defaultRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MIN_FILE = ".github/toolchain-min.txt";
const WORKFLOWS_DIR = ".github/workflows";
const KEYS = ["swift", "xcode"];
const VERSION = /^(\d+\.\d+(?:\.\d+)?)$/;
const SWIFT_IMAGE = /\bswift:(\d+\.\d+(?:\.\d+)?)/g;
const XCODE_VERSION_KEY =
  /['"]?xcode-version['"]?\s*:\s*['"]?(\d+\.\d+(?:\.\d+)?)['"]?/g;
const DEVELOPER_DIR_XCODE =
  /DEVELOPER_DIR[^\n#]*Xcode_(\d+\.\d+(?:\.\d+)?)\.app/g;
const XCODE_APP = /Xcode_(\d+\.\d+(?:\.\d+)?)\.app/g;

function compareVersions(found, min) {
  const a = found.split(".").map(Number);
  const b = min.split(".").map(Number);
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const av = a[i] ?? 0;
    const bv = b[i] ?? 0;
    if (av < bv) {
      return -1;
    }
    if (av > bv) {
      return 1;
    }
  }
  return 0;
}

function parseMinFile(text) {
  const lines = String(text)
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .split("\n");
  while (lines.length > 0 && lines[lines.length - 1] === "") {
    lines.pop();
  }
  if (lines.length !== 2) {
    return null;
  }
  const map = Object.create(null);
  for (const line of lines) {
    const eq = line.indexOf("=");
    if (eq <= 0) {
      return null;
    }
    const key = line.slice(0, eq);
    const value = line.slice(eq + 1);
    if (!KEYS.includes(key) || map[key] != null || !VERSION.test(value)) {
      return null;
    }
    map[key] = value;
  }
  if (map.swift == null || map.xcode == null) {
    return null;
  }
  return map;
}

function unique(values) {
  return [...new Set(values)];
}

function yamlQuoteCanStart(prev) {
  return prev === "" || /[\s:[{\n,]/.test(prev);
}

function yamlCommentCanStart(prev) {
  return prev === "" || /[ \t\n]/.test(prev);
}

function stripYamlComments(text) {
  let out = "";
  let quote = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    const prev = i === 0 ? "" : text[i - 1];
    if (quote === '"') {
      out += c;
      if (c === "\\" && i + 1 < text.length) {
        out += text[i + 1];
        i += 1;
        continue;
      }
      if (c === '"') {
        quote = null;
      }
      continue;
    }
    if (quote === "'") {
      out += c;
      if (c === "'" && text[i + 1] === "'") {
        out += text[i + 1];
        i += 1;
        continue;
      }
      if (c === "'") {
        quote = null;
      }
      continue;
    }
    if ((c === '"' || c === "'") && yamlQuoteCanStart(prev)) {
      quote = c;
      out += c;
      continue;
    }
    if (c === "#" && yamlCommentCanStart(prev)) {
      while (i < text.length && text[i] !== "\n") {
        i += 1;
      }
      if (i < text.length) {
        out += "\n";
      }
      continue;
    }
    out += c;
  }
  return out;
}

function matches(re, text) {
  const found = [];
  re.lastIndex = 0;
  let match;
  while ((match = re.exec(text)) !== null) {
    found.push(match[1]);
  }
  return found;
}

function workflowFiles(root) {
  const dir = path.join(root, WORKFLOWS_DIR);
  return fs
    .readdirSync(dir)
    .filter((name) => name.endsWith(".yml") || name.endsWith(".yaml"))
    .sort()
    .map((name) => path.join(WORKFLOWS_DIR, name));
}

function failLine(file, kind, found, min) {
  return `${file}: version ${kind} ${found} plus ancienne que le minimum ${min}\n`;
}

function main(argv = process.argv.slice(2)) {
  const root = path.resolve(argv[0] ?? defaultRoot);
  const minPath = path.join(root, MIN_FILE);
  let raw;
  try {
    raw = fs.readFileSync(minPath, "utf8");
  } catch (err) {
    if (err && err.code === "ENOENT") {
      process.stderr.write(`${MIN_FILE}: fichier absent\n`);
      return 1;
    }
    throw err;
  }
  const mins = parseMinFile(raw);
  if (mins == null) {
    process.stderr.write(`${MIN_FILE}: fichier mal formé\n`);
    return 1;
  }

  let failed = false;
  let xcodePins = 0;
  let files;
  try {
    files = workflowFiles(root);
  } catch (err) {
    process.stderr.write(`${WORKFLOWS_DIR}: ${err.message}\n`);
    return 1;
  }

  for (const rel of files) {
    const text = stripYamlComments(fs.readFileSync(path.join(root, rel), "utf8"));
    for (const found of unique(matches(SWIFT_IMAGE, text))) {
      if (compareVersions(found, mins.swift) < 0) {
        process.stderr.write(failLine(rel, "swift", found, mins.swift));
        failed = true;
      }
    }
    const xcodeFound = unique([
      ...matches(XCODE_VERSION_KEY, text),
      ...matches(DEVELOPER_DIR_XCODE, text),
      ...matches(XCODE_APP, text),
    ]);
    xcodePins += xcodeFound.length;
    for (const found of xcodeFound) {
      if (compareVersions(found, mins.xcode) < 0) {
        process.stderr.write(failLine(rel, "xcode", found, mins.xcode));
        failed = true;
      }
    }
  }

  if (xcodePins === 0) {
    process.stdout.write("aucune version Xcode fixée dans les workflows\n");
  }
  return failed ? 1 : 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exitCode = main();
}

export { compareVersions, main, parseMinFile };
