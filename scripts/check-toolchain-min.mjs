#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMap, isPair, isScalar, isSeq, LineCounter, parseAllDocuments, visit } from "yaml";

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

function scalarText(node) {
  if (typeof node.value === "number" || typeof node.value === "bigint") {
    if (typeof node.source === "string" && node.source !== "") {
      return node.source;
    }
  }
  if (node.value == null) {
    return "";
  }
  return String(node.value);
}

function pairKey(pair) {
  if (!isPair(pair) || pair.key == null) {
    return null;
  }
  if (isScalar(pair.key)) {
    return pair.key.value == null ? null : String(pair.key.value);
  }
  return null;
}

function collectFromNode(node, swiftFound, xcodeFound, key, seen) {
  if (node == null) {
    return;
  }
  if (isScalar(node)) {
    const text = scalarText(node);
    collectSwiftFromImage(text, swiftFound);
    if (key === "xcode-version") {
      collectXcodeVersion(text, xcodeFound);
    }
    if (key === "DEVELOPER_DIR") {
      collectXcodeFromText(text, xcodeFound);
    }
    if (XCODE_IN_RUN.test(text)) {
      collectXcodeFromText(text, xcodeFound);
    }
    return;
  }
  if (typeof node !== "object") {
    return;
  }
  if (seen.has(node)) {
    return;
  }
  seen.add(node);
  try {
    if (isPair(node)) {
      collectFromNode(node.value, swiftFound, xcodeFound, pairKey(node) ?? key, seen);
      return;
    }
    if (isMap(node) || isSeq(node)) {
      for (const item of node.items) {
        collectFromNode(item, swiftFound, xcodeFound, key, seen);
      }
    }
  } finally {
    seen.delete(node);
  }
}

function collectFromDocument(doc, swiftFound, xcodeFound) {
  collectFromNode(doc.contents, swiftFound, xcodeFound, null, new WeakSet());
}

function nodeLine(node, lineCounter) {
  if (!node || !Array.isArray(node.range) || typeof node.range[0] !== "number") {
    return 1;
  }
  const pos = lineCounter.linePos(node.range[0]);
  return pos.line > 0 ? pos.line : 1;
}

function aliasName(node) {
  const raw = typeof node.source === "string" ? node.source : "";
  return raw.replace(/:$/, "");
}

function firstAnchorOrAlias(doc, lineCounter) {
  let hit = null;
  visit(doc, {
    Alias(_key, node) {
      if (hit) {
        return visit.BREAK;
      }
      hit = {
        kind: "alias",
        name: aliasName(node),
        line: nodeLine(node, lineCounter),
      };
      return visit.BREAK;
    },
    Node(_key, node) {
      if (hit) {
        return visit.BREAK;
      }
      if (node && typeof node.anchor === "string" && node.anchor !== "") {
        hit = {
          kind: "ancre",
          name: node.anchor,
          line: nodeLine(node, lineCounter),
        };
        return visit.BREAK;
      }
    },
  });
  return hit;
}

function refuseAnchorOrAliasLine(file, hit) {
  if (hit.kind === "ancre") {
    return `${file}:${hit.line}: ancre YAML &${hit.name} refusée\n`;
  }
  return `${file}:${hit.line}: alias YAML *${hit.name} refusé\n`;
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
    const lineCounter = new LineCounter();
    let docs;
    try {
      docs = parseAllDocuments(text, { prettyErrors: true, lineCounter });
    } catch (err) {
      process.stderr.write(yamlErrorLine(rel, err));
      failed = true;
      continue;
    }
    let refused = null;
    const parseErrors = [];
    for (const doc of docs) {
      if (refused == null) {
        refused = firstAnchorOrAlias(doc, lineCounter);
      }
      if (doc.errors && doc.errors.length > 0) {
        parseErrors.push(...doc.errors);
      }
    }
    if (refused) {
      process.stderr.write(refuseAnchorOrAliasLine(rel, refused));
      failed = true;
      continue;
    }
    if (parseErrors.length > 0) {
      process.stderr.write(yamlErrorLine(rel, parseErrors[0]));
      failed = true;
      continue;
    }

    const swiftFound = [];
    const xcodeFound = [];
    for (const doc of docs) {
      collectFromDocument(doc, swiftFound, xcodeFound);
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
