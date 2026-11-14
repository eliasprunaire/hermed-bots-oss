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

function createNoopTracker() {
  return {
    isInMultilineString() {
      return false;
    },
    consume() {},
  };
}

function createJsTracker() {
  const stack = ["code"];
  const braces = [0];
  let quote = null;
  let blockComment = false;

  return {
    isInMultilineString() {
      if (quote) {
        return true;
      }
      return stack[stack.length - 1] === "template";
    },
    consume(line) {
      let i = 0;
      while (i < line.length) {
        if (blockComment) {
          const end = line.indexOf("*/", i);
          if (end === -1) {
            return;
          }
          i = end + 2;
          blockComment = false;
          continue;
        }
        if (quote) {
          while (i < line.length) {
            if (line[i] === "\\") {
              i += 2;
              continue;
            }
            if (line[i] === quote) {
              quote = null;
              i += 1;
              break;
            }
            i += 1;
          }
          if (quote) {
            if (!line.endsWith("\\")) {
              quote = null;
            }
            return;
          }
          continue;
        }
        if (stack[stack.length - 1] === "template") {
          if (line[i] === "\\") {
            i += 2;
            continue;
          }
          if (line[i] === "`") {
            stack.pop();
            braces.pop();
            i += 1;
            continue;
          }
          if (line[i] === "$" && line[i + 1] === "{") {
            stack.push("code");
            braces.push(1);
            i += 2;
            continue;
          }
          i += 1;
          continue;
        }
        if (line[i] === "/" && line[i + 1] === "/") {
          return;
        }
        if (line[i] === "/" && line[i + 1] === "*") {
          blockComment = true;
          i += 2;
          continue;
        }
        if (line[i] === "'" || line[i] === '"') {
          quote = line[i];
          i += 1;
          continue;
        }
        if (line[i] === "`") {
          stack.push("template");
          braces.push(0);
          i += 1;
          continue;
        }
        if (line[i] === "{") {
          braces[braces.length - 1] += 1;
          i += 1;
          continue;
        }
        if (line[i] === "}") {
          if (stack.length > 1) {
            braces[braces.length - 1] -= 1;
            if (braces[braces.length - 1] === 0) {
              stack.pop();
              braces.pop();
            }
          }
          i += 1;
          continue;
        }
        i += 1;
      }
    },
  };
}

function pythonStringStart(line, i) {
  const prefix = /^(?:[rR][fF]|[fF][rR]|[rR][bB]|[bB][rR]|[rRuUfFbB])?/.exec(
    line.slice(i),
  );
  const next = i + (prefix ? prefix[0].length : 0);
  if (line.startsWith('"""', next) || line.startsWith("'''", next)) {
    return { kind: "triple", quote: line.slice(next, next + 3), next: next + 3 };
  }
  if (line[next] === '"' || line[next] === "'") {
    return { kind: "single", quote: line[next], next: next + 1 };
  }
  return null;
}

function findUnescaped(line, from, token) {
  let i = from;
  while (i < line.length) {
    if (line[i] === "\\") {
      i += 2;
      continue;
    }
    if (line.startsWith(token, i)) {
      return i;
    }
    i += 1;
  }
  return -1;
}

function createPythonTracker() {
  let triple = null;

  return {
    isInMultilineString() {
      return triple !== null;
    },
    consume(line) {
      let i = 0;
      if (triple) {
        const end = findUnescaped(line, 0, triple);
        if (end === -1) {
          return;
        }
        i = end + triple.length;
        triple = null;
      }
      while (i < line.length) {
        if (line[i] === "#") {
          return;
        }
        const start = pythonStringStart(line, i);
        if (!start) {
          i += 1;
          continue;
        }
        if (start.kind === "triple") {
          const end = findUnescaped(line, start.next, start.quote);
          if (end === -1) {
            triple = start.quote;
            return;
          }
          i = end + start.quote.length;
          continue;
        }
        const end = findUnescaped(line, start.next, start.quote);
        if (end === -1) {
          return;
        }
        i = end + 1;
      }
    },
  };
}

function createShellTracker() {
  const queue = [];

  return {
    isInMultilineString() {
      return queue.length > 0;
    },
    consume(line) {
      if (queue.length > 0) {
        const top = queue[0];
        const candidate = top.stripTabs ? line.replace(/^\t+/, "") : line;
        if (candidate === top.delim) {
          queue.shift();
        }
        return;
      }
      let i = 0;
      let quote = null;
      while (i < line.length) {
        const c = line[i];
        if (quote) {
          if (c === "\\" && quote !== "'") {
            i += 2;
            continue;
          }
          if (c === quote) {
            quote = null;
          }
          i += 1;
          continue;
        }
        if (c === "#") {
          return;
        }
        if (c === "'" || c === '"' || c === "`") {
          quote = c;
          i += 1;
          continue;
        }
        if (c === "<" && line[i + 1] === "<" && line[i + 2] !== "<") {
          i += 2;
          let stripTabs = false;
          if (line[i] === "-") {
            stripTabs = true;
            i += 1;
          }
          while (line[i] === " " || line[i] === "\t") {
            i += 1;
          }
          let delim = null;
          if (line[i] === "'") {
            const end = line.indexOf("'", i + 1);
            if (end === -1) {
              return;
            }
            delim = line.slice(i + 1, end);
            i = end + 1;
          } else if (line[i] === '"') {
            const end = line.indexOf('"', i + 1);
            if (end === -1) {
              return;
            }
            delim = line.slice(i + 1, end);
            i = end + 1;
          } else if (line[i] === "\\") {
            const m = /^\\(\S+)/.exec(line.slice(i));
            if (!m) {
              i += 1;
              continue;
            }
            delim = m[1];
            i += m[0].length;
          } else {
            const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(line.slice(i));
            if (!m) {
              continue;
            }
            delim = m[0];
            i += m[0].length;
          }
          if (delim) {
            queue.push({ delim, stripTabs });
          }
          continue;
        }
        i += 1;
      }
    },
  };
}

function makeTracker(ext) {
  if (ext === ".js" || ext === ".mjs" || ext === ".cjs") {
    return createJsTracker();
  }
  if (ext === ".py") {
    return createPythonTracker();
  }
  if (ext === ".sh") {
    return createShellTracker();
  }
  return createNoopTracker();
}

function scanText(label, text, ext) {
  const findings = [];
  const lines = String(text).split(/\r?\n/);
  const tracker = makeTracker(ext);
  for (let i = 0; i < lines.length; i += 1) {
    if (!tracker.isInMultilineString()) {
      const hit = commentMatch(lines[i], ext);
      if (hit && hasPointFinal(hit.body)) {
        findings.push(`${label}:${i + 1}: POINT_FINAL`);
      }
    }
    tracker.consume(lines[i]);
  }
  return findings;
}

function rewriteText(text, ext) {
  const endsWithNl = text.endsWith("\n");
  const raw = endsWithNl ? text.slice(0, -1) : text;
  const lines = raw.split("\n");
  const tracker = makeTracker(ext);
  const next = lines.map((line) => {
    let out = line;
    if (!tracker.isInMultilineString()) {
      const hit = commentMatch(line, ext);
      if (hit && hasPointFinal(hit.body)) {
        const trimmed = hit.body.replace(/[ \t]+$/, "");
        out = `${hit.indent}${hit.marker}${trimmed.slice(0, -1)}`;
      }
    }
    tracker.consume(line);
    return out;
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
