"use strict";

const fs = require("node:fs");
const path = require("node:path");

const COLUMNS = Object.freeze(["date", "PR", "sha de squash", "vérificateur"]);
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const PR_RE = /^#?\d+$/;
const SHA_RE = /^[0-9a-f]{40}$/;

function parseRoot(argv) {
  if (argv.length === 0) {
    return path.resolve(__dirname, "..");
  }
  if (argv.length === 2 && argv[0] === "--root") {
    return path.resolve(argv[1]);
  }
  if (argv.length === 2 && argv[0] === "--file") {
    return { file: path.resolve(argv[1]) };
  }
  process.stderr.write(
    "usage: node scripts/check-fusions.js [--root DIR | --file PATH]\n",
  );
  return null;
}

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (err) {
    if (err && err.code === "ENOENT") {
      return null;
    }
    throw err;
  }
}

function splitRow(line) {
  const trimmed = line.trim();
  const inner = trimmed.replace(/^\|/, "").replace(/\|$/, "");
  return inner.split("|").map((cell) => cell.trim());
}

function isSeparator(cells) {
  return (
    cells.length > 0 &&
    cells.every((cell) => /^:?-{3,}:?$/.test(cell))
  );
}

function validDate(text) {
  const match = DATE_RE.exec(text);
  if (!match) {
    return false;
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
}

function checkMarkdown(markdown, label) {
  const errors = [];
  if (markdown == null) {
    return [`missing ${label}`];
  }
  const lines = markdown.split(/\r?\n/);
  let header = null;
  let seenSeparator = false;
  let headerLine = 0;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (!line.startsWith("|")) {
      continue;
    }
    const cells = splitRow(line);
    const lineNo = i + 1;
    if (header == null) {
      header = cells;
      headerLine = lineNo;
      if (header.length !== COLUMNS.length) {
        errors.push(
          `${label}:${lineNo}: expected ${COLUMNS.length} header columns`,
        );
      }
      for (let c = 0; c < COLUMNS.length; c += 1) {
        if (header[c] !== COLUMNS[c]) {
          errors.push(
            `${label}:${lineNo}: column ${c + 1} must be ${COLUMNS[c]}`,
          );
        }
      }
      continue;
    }
    if (!seenSeparator) {
      if (cells.length !== header.length || !isSeparator(cells)) {
        errors.push(`${label}:${lineNo}: malformed table separator`);
      }
      seenSeparator = true;
      continue;
    }
    if (cells.length !== COLUMNS.length) {
      errors.push(
        `${label}:${lineNo}: expected ${COLUMNS.length} cells, got ${cells.length}`,
      );
      continue;
    }
    const [date, pr, sha, verifier] = cells;
    if (!validDate(date)) {
      errors.push(`${label}:${lineNo}: malformed date`);
    }
    if (!PR_RE.test(pr)) {
      errors.push(`${label}:${lineNo}: malformed PR`);
    }
    if (!SHA_RE.test(sha)) {
      errors.push(`${label}:${lineNo}: malformed sha de squash`);
    }
    if (verifier === "") {
      errors.push(`${label}:${lineNo}: empty vérificateur`);
    }
  }
  if (header == null) {
    errors.push(`${label}: missing table header`);
  } else if (!seenSeparator) {
    errors.push(`${label}:${headerLine}: missing table separator`);
  }
  return errors;
}

function journalPath(root) {
  return path.join(root, "docs", "fusions.md");
}

function checkRoot(root) {
  const file = journalPath(root);
  return checkMarkdown(readText(file), "docs/fusions.md");
}

function checkFile(file) {
  return checkMarkdown(readText(file), path.basename(file));
}

function main(argv = process.argv.slice(2)) {
  const parsed = parseRoot(argv);
  if (parsed == null) {
    return 1;
  }
  const errors =
    typeof parsed === "object" && parsed.file
      ? checkFile(parsed.file)
      : checkRoot(parsed);
  if (errors.length > 0) {
    process.stderr.write(`${errors.join("\n")}\n`);
    return 1;
  }
  process.stdout.write("ok\n");
  return 0;
}

module.exports = {
  COLUMNS,
  checkFile,
  checkMarkdown,
  checkRoot,
  main,
};

if (require.main === module) {
  process.exitCode = main();
}
