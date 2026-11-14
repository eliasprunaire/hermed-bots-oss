"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const SOURCE_EXT = new Set([".js", ".mjs", ".cjs", ".sh", ".py", ".swift"]);

const HASH_EXT = new Set([".sh", ".py"]);
const SLASH_EXT = new Set([".js", ".mjs", ".cjs", ".swift"]);

// à retirer après fusion de #172
const EXCLUDED_OPEN_PRS = Object.freeze([
  { pr: 172, path: "HermedBots/App/AppModel.swift" },
  { pr: 172, path: "HermedBots/Bots/" },
]);

// Portes CI (GATE_FILES) : ne pas modifier ces fichiers
const EXCLUDED_GATE = Object.freeze(["scripts/check-protected-paths.js"]);

// Fichiers réservés (code du lanceur, portes CI)
const EXCLUDED_RESERVED = Object.freeze([
  "scripts/dev-lead-runner/",
  "scripts/infra-guard-ci.js",
]);

function trackedSourceFiles(root) {
  const listed = spawnSync(
    "git",
    ["ls-files", "-z", "--", "*.js", "*.mjs", "*.cjs", "*.sh", "*.py", "*.swift"],
    { cwd: root, encoding: "buffer" },
  );
  if (listed.error) {
    throw listed.error;
  }
  if (listed.status !== 0) {
    const errText = listed.stderr && listed.stderr.length
      ? listed.stderr
      : Buffer.from("git ls-files failed\n");
    process.stderr.write(errText);
    process.exit(listed.status || 1);
  }
  return listed.stdout.toString("utf8").split("\0").filter(Boolean);
}

function posixRel(file, root) {
  const abs = path.resolve(root, file);
  const base = path.resolve(root);
  const rel = path.relative(base, abs);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    return null;
  }
  return rel.split(path.sep).join("/");
}

function isExcluded(rel) {
  if (!rel) {
    return false;
  }
  for (const item of EXCLUDED_OPEN_PRS) {
    const p = item.path;
    if (p.endsWith("/")) {
      if (rel === p.slice(0, -1) || rel.startsWith(p)) {
        return true;
      }
    } else if (rel === p) {
      return true;
    }
  }
  for (const p of EXCLUDED_RESERVED) {
    if (p.endsWith("/")) {
      if (rel === p.slice(0, -1) || rel.startsWith(p)) {
        return true;
      }
    } else if (rel === p) {
      return true;
    }
  }
  return EXCLUDED_GATE.includes(rel);
}

function commentMatch(line, ext) {
  if (HASH_EXT.has(ext)) {
    if (/^#!/.test(line)) {
      return null;
    }
    const match = /^(\s*)#(.*)$/.exec(line);
    return match
      ? { indent: match[1], marker: "#", body: match[2] }
      : null;
  }
  if (SLASH_EXT.has(ext)) {
    const match = /^(\s*)(\/\/\/|\/\/)(.*)$/.exec(line);
    return match
      ? { indent: match[1], marker: match[2], body: match[3] }
      : null;
  }
  return null;
}

function hasPointFinal(body) {
  const trimmed = String(body).replace(/[ \t]+$/, "");
  if (!trimmed.endsWith(".")) {
    return false;
  }
  if (trimmed.endsWith("..")) {
    return false;
  }
  return true;
}

function scanText(label, text, ext) {
  const findings = [];
  const lines = String(text).split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const hit = commentMatch(lines[i], ext);
    if (!hit || !hasPointFinal(hit.body)) {
      continue;
    }
    findings.push(`${label}:${i + 1}: POINT_FINAL`);
  }
  return findings;
}

function rewriteText(text, ext) {
  const endsWithNl = text.endsWith("\n");
  const raw = endsWithNl ? text.slice(0, -1) : text;
  const lines = raw.split("\n");
  const next = lines.map((line) => {
    const hit = commentMatch(line, ext);
    if (!hit || !hasPointFinal(hit.body)) {
      return line;
    }
    const trimmed = hit.body.replace(/[ \t]+$/, "");
    return `${hit.indent}${hit.marker}${trimmed.slice(0, -1)}`;
  });
  return next.join("\n") + (endsWithNl ? "\n" : "");
}

function scanFiles(files, root) {
  const findings = [];
  for (const file of files) {
    const ext = path.extname(file);
    if (!SOURCE_EXT.has(ext)) {
      continue;
    }
    const rel = posixRel(file, root);
    if (isExcluded(rel)) {
      continue;
    }
    const abs = path.resolve(root, file);
    const text = fs.readFileSync(abs, "utf8");
    const label = rel || file;
    findings.push(...scanText(label, text, ext));
  }
  return findings;
}

function rewriteFile(file, root) {
  const ext = path.extname(file);
  if (!SOURCE_EXT.has(ext)) {
    return false;
  }
  const rel = posixRel(file, root);
  if (isExcluded(rel)) {
    return false;
  }
  const abs = path.resolve(root, file);
  const orig = fs.readFileSync(abs, "utf8");
  const next = rewriteText(orig, ext);
  if (next === orig) {
    return false;
  }
  fs.writeFileSync(abs, next);
  return true;
}

function main(argv = process.argv.slice(2), root = path.resolve(__dirname, "..")) {
  const files = argv.length > 0 ? argv : trackedSourceFiles(root);
  const findings = scanFiles(files, root);
  for (const line of findings) {
    process.stderr.write(`${line}\n`);
  }
  return findings.length > 0 ? 1 : 0;
}

module.exports = {
  EXCLUDED_GATE,
  EXCLUDED_OPEN_PRS,
  EXCLUDED_RESERVED,
  SOURCE_EXT,
  hasPointFinal,
  isExcluded,
  main,
  rewriteFile,
  rewriteText,
  scanFiles,
  scanText,
  trackedSourceFiles,
};

if (require.main === module) {
  process.exitCode = main();
}
