#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseAllDocuments } from "yaml";

const defaultRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MIN_FILE = ".github/toolchain-min.txt";
const WORKFLOWS_DIR = ".github/workflows";
const KEYS = ["swift", "xcode"];
const VERSION = /^(\d+\.\d+(?:\.\d+)?)$/;
const INTEGER_VERSION = /^\d+$/;
const SWIFT_IMAGE = /\bswift:(\d+\.\d+(?:\.\d+)?)/g;
const XCODE_APP = /Xcode_(\d+\.\d+(?:\.\d+)?)\.app/g;
const XCODE_IN_RUN = /DEVELOPER_DIR|xcode-select/;

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

function matches(re, text) {
  const found = [];
  re.lastIndex = 0;
  let match;
  while ((match = re.exec(text)) !== null) {
    found.push(match[1]);
  }
  return found;
}

function collectSwiftFromImage(text, into) {
  if (text == null) {
    return;
  }
  into.push(...matches(SWIFT_IMAGE, text));
}

function collectXcodeFromText(text, into) {
  if (text == null) {
    return;
  }
  into.push(...matches(XCODE_APP, text));
}

function collectXcodeVersion(text, into) {
  if (text == null) {
    return;
  }
  const trimmed = String(text).trim();
  if (VERSION.test(trimmed) || INTEGER_VERSION.test(trimmed)) {
    into.push(trimmed);
    return;
  }
  into.push(...matches(/(\d+\.\d+(?:\.\d+)?)/g, trimmed));
}

function collectFromValue(value, swiftFound, xcodeFound, key, seen) {
  if (value == null) {
    return;
  }
  if (typeof value === "string") {
    if (key !== "version") {
      collectSwiftFromImage(value, swiftFound);
    }
    if (key === "xcode-version") {
      collectXcodeVersion(value, xcodeFound);
    }
    if (key === "DEVELOPER_DIR") {
      collectXcodeFromText(value, xcodeFound);
    }
    if (XCODE_IN_RUN.test(value)) {
      collectXcodeFromText(value, xcodeFound);
    }
    return;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    if (key === "xcode-version") {
      collectXcodeVersion(String(value), xcodeFound);
    }
    return;
  }
  if (typeof value !== "object") {
    return;
  }
  if (seen.has(value)) {
    return;
  }
  seen.add(value);
  try {
    if (Array.isArray(value)) {
      for (const item of value) {
        collectFromValue(item, swiftFound, xcodeFound, key, seen);
      }
      return;
    }
    for (const [childKey, child] of Object.entries(value)) {
      collectFromValue(child, swiftFound, xcodeFound, childKey, seen);
    }
  } finally {
    seen.delete(value);
  }
}

function collectFromDocument(doc, swiftFound, xcodeFound) {
  collectFromValue(doc.toJS(), swiftFound, xcodeFound, null, new WeakSet());
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

function yamlErrorLine(file, err) {
  const detail = err && err.message ? String(err.message).replace(/\s+/g, " ").trim() : "";
  if (detail === "") {
    return `${file}: YAML invalide\n`;
  }
  return `${file}: YAML invalide : ${detail}\n`;
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
    const text = fs.readFileSync(path.join(root, rel), "utf8");
    let docs;
    try {
      docs = parseAllDocuments(text, { prettyErrors: true });
    } catch (err) {
      process.stderr.write(yamlErrorLine(rel, err));
      failed = true;
      continue;
    }
    const parseErrors = [];
    for (const doc of docs) {
      if (doc.errors && doc.errors.length > 0) {
        parseErrors.push(...doc.errors);
      }
    }
    if (parseErrors.length > 0) {
      process.stderr.write(yamlErrorLine(rel, parseErrors[0]));
      failed = true;
      continue;
    }

    const swiftFound = [];
    const xcodeFound = [];
    let jsFailed = false;
    for (const doc of docs) {
      try {
        collectFromDocument(doc, swiftFound, xcodeFound);
      } catch (err) {
        process.stderr.write(yamlErrorLine(rel, err));
        failed = true;
        jsFailed = true;
        break;
      }
    }
    if (jsFailed) {
      continue;
    }

    for (const found of unique(swiftFound)) {
      if (compareVersions(found, mins.swift) < 0) {
        process.stderr.write(failLine(rel, "swift", found, mins.swift));
        failed = true;
      }
    }
    const xcodeUnique = unique(xcodeFound);
    xcodePins += xcodeUnique.length;
    for (const found of xcodeUnique) {
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
