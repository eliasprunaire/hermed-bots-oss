"use strict";

const MARKER = "<!-- dev-lead-verifier -->";
const VERDICT_LINE = /^VERDICT: (PASS\+NOTES|PASS|FAIL) @ ([0-9a-fA-F]{40})$/;

function fenceOpen(line) {
  const match = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
  if (!match) {
    return null;
  }
  return {
    char: match[2][0],
    len: match[2].length,
    rest: match[3],
  };
}

function isClosingFence(line, fence) {
  const open = fenceOpen(line);
  return (
    open != null &&
    open.char === fence.char &&
    open.len >= fence.len &&
    open.rest.trim() === ""
  );
}

function plainLines(body) {
  const lines = [];
  let fence = null;
  let inQuote = false;
  for (const rawLine of String(body).split("\n")) {
    const line = rawLine.replace(/\r$/, "");
    if (fence) {
      if (isClosingFence(line, fence)) {
        fence = null;
      }
      continue;
    }
    if (line.trim() === "") {
      inQuote = false;
      lines.push(line);
      continue;
    }
    if (/^ {0,3}>/.test(line)) {
      inQuote = true;
      continue;
    }
    if (inQuote) {
      const open = fenceOpen(line);
      if (open) {
        inQuote = false;
        fence = open;
      }
      continue;
    }
    const open = fenceOpen(line);
    if (open) {
      fence = open;
      continue;
    }
    if (/^(?: {4}|\t)/.test(line)) {
      continue;
    }
    lines.push(line);
  }
  return lines;
}

function withoutCodeSpans(text) {
  let out = "";
  let index = 0;
  while (index < text.length) {
    if (text[index] !== "`") {
      out += text[index];
      index += 1;
      continue;
    }
    let size = 1;
    while (text[index + size] === "`") {
      size += 1;
    }
    const close = text.indexOf("`".repeat(size), index + size);
    if (close === -1) {
      out += text.slice(index);
      break;
    }
    if (text.slice(index + size, close).includes("\n")) {
      out += "\n";
    }
    index = close + size;
  }
  return out;
}

function prose(body) {
  return withoutCodeSpans(plainLines(body).join("\n"));
}

function verdictLines(body) {
  const found = [];
  for (const line of prose(body).split("\n")) {
    const match = VERDICT_LINE.exec(line);
    if (match) {
      found.push({ verdict: match[1], sha: match[2].toLowerCase() });
    }
  }
  return found;
}

function plainMarker(body) {
  return prose(body).includes(MARKER);
}

module.exports = {
  MARKER,
  VERDICT_LINE,
  prose,
  verdictLines,
  plainMarker,
};
