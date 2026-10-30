"use strict";

const { readFileSync } = require("node:fs");

const CO_AUTHORED_LINE = /^[ \t]*#*[ \t]*Co-authored-by[ \t]*:/i;

const FORBIDDEN = [
  { id: "Co-authored-by", re: /^[ \t]*#*[ \t]*Co-authored-by[ \t]*:/im },
  { id: "Open in Cursor", re: /\bOpen in Cursor\b/i },
  { id: "cursor.com/agents", re: /cursor\.com\/agents(?=\/|[?#]|["'\s]|$)/i },
];

const AGENT_SLOT = "AGENT_ID";
const AGENT_SLOT_RE = /[^\r\n\u2028\u2029"?&<>]+/;

const HOST_FOOTER_TEMPLATES = [
  [
    '<div><a href="https://cursor.com/agents/',
    AGENT_SLOT,
    '?cursor_ref=pr_footer&cursor_cta=open_in_web"><picture>',
    '<source media="(prefers-color-scheme: dark)" srcset="https://cursor.com/assets/images/open-in-web-dark.png">',
    '<source media="(prefers-color-scheme: light)" srcset="https://cursor.com/assets/images/open-in-web-light.png">',
    '<img alt="Open in Web" width="114" height="28" src="https://cursor.com/assets/images/open-in-web-dark.png">',
    "</picture></a>&nbsp;<a href=\"https://cursor.com/background-agent?bcId=",
    AGENT_SLOT,
    '&cursor_ref=pr_footer&cursor_cta=open_in_cursor"><picture>',
    '<source media="(prefers-color-scheme: dark)" srcset="https://cursor.com/assets/images/open-in-cursor-dark.png">',
    '<source media="(prefers-color-scheme: light)" srcset="https://cursor.com/assets/images/open-in-cursor-light.png">',
    '<img alt="Open in Cursor" width="131" height="28" src="https://cursor.com/assets/images/open-in-cursor-dark.png">',
    "</picture></a>&nbsp;</div>",
  ].join(""),
  [
    '<div><a href="https://cursor.com/agents/',
    AGENT_SLOT,
    '"><img alt="Open in Cursor"></a></div>',
  ].join(""),
];

function footerPattern(template) {
  const escaped = template.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const slotted = escaped.replaceAll(AGENT_SLOT, AGENT_SLOT_RE.source);
  return new RegExp(`${slotted}\\s*$`);
}

const HOST_FOOTERS = HOST_FOOTER_TEMPLATES.map(footerPattern);

const AGENTS_HEADING = /^##[ \t]+Agents[ \t]*$/;
const NEXT_H2 = /^##[ \t]+/;
const BC_UUID =
  /(?<![A-Za-z0-9])bc-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9a-fA-F-])/;

function authoredPrBody(text) {
  let body = String(text ?? "");
  for (const pattern of HOST_FOOTERS) {
    body = body.replace(pattern, "");
  }
  return body;
}

function isCoAuthoredByLine(line) {
  return CO_AUTHORED_LINE.test(String(line).replace(/\r$/, ""));
}

function stripCoAuthoredBy(text) {
  return String(text ?? "")
    .split("\n")
    .filter((line) => !isCoAuthoredByLine(line))
    .join("\n");
}

function hitsIn(text) {
  if (text == null || text === "") {
    return [];
  }
  return FORBIDDEN.filter((rule) => rule.re.test(String(text))).map(
    (rule) => rule.id,
  );
}

function checkSources(sources) {
  const failures = [];
  for (const source of sources) {
    const text =
      source.label === "PR body" ? authoredPrBody(source.text) : source.text;
    for (const id of hitsIn(text)) {
      failures.push(`${source.label} contains ${id}`);
    }
  }
  return failures;
}

function stripHtmlComments(text) {
  let out = "";
  let index = 0;
  while (index < text.length) {
    const open = text.indexOf("<!--", index);
    if (open === -1) {
      out += text.slice(index);
      break;
    }
    out += text.slice(index, open);
    const close = text.indexOf("-->", open + 4);
    if (close === -1) {
      break;
    }
    index = close + 3;
  }
  return out;
}

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

function visibleLines(text) {
  const lines = [];
  let fence = null;
  for (const rawLine of String(text).split("\n")) {
    const line = rawLine.replace(/\r$/, "");
    if (fence) {
      if (isClosingFence(line, fence)) {
        fence = null;
      }
      continue;
    }
    const open = fenceOpen(line);
    if (open) {
      fence = open;
      continue;
    }
    lines.push(line);
  }
  return lines;
}

function agentsFailures(text) {
  const lines = visibleLines(stripHtmlComments(text));
  const start = lines.findIndex((line) => AGENTS_HEADING.test(line));
  if (start === -1) {
    return ["PR body is missing a ## Agents heading"];
  }
  const rest = lines.slice(start + 1);
  const next = rest.findIndex((line) => NEXT_H2.test(line));
  const section = (next === -1 ? rest : rest.slice(0, next)).join("\n");
  if (!BC_UUID.test(section)) {
    return ["PR body ## Agents has no bc- UUID"];
  }
  return [];
}

function explicitSquashBody() {
  return "";
}

function flagValue(argv, flag) {
  const index = argv.indexOf(flag);
  if (index === -1) {
    return { missing: true };
  }
  const value = argv[index + 1];
  if (value == null || value.startsWith("--")) {
    return { missing: true, empty: true };
  }
  return { path: value };
}

function readRequiredFile(path) {
  try {
    return { text: readFileSync(path, "utf8") };
  } catch (err) {
    if (err && err.code === "ENOENT") {
      return { error: `missing file: ${path}` };
    }
    throw err;
  }
}

function squashBodyText(squashFlag) {
  if (squashFlag.missing) {
    return { text: explicitSquashBody() };
  }
  return readRequiredFile(squashFlag.path);
}

function main(argv = process.argv.slice(2)) {
  if (argv.includes("--print-squash-body")) {
    process.stdout.write(explicitSquashBody());
    return 0;
  }
  const body = flagValue(argv, "--body-file");
  const commits = flagValue(argv, "--commits-file");
  const squash = flagValue(argv, "--squash-body-file");
  if (body.missing || commits.missing || squash.empty) {
    console.error(
      "usage: check-pr-attribution.js --body-file <path> --commits-file <path> [--squash-body-file <path>]",
    );
    return 1;
  }
  const bodyFile = readRequiredFile(body.path);
  if (bodyFile.error) {
    console.error(bodyFile.error);
    return 1;
  }
  const commitsFile = readRequiredFile(commits.path);
  if (commitsFile.error) {
    console.error(commitsFile.error);
    return 1;
  }
  const squashFile = squashBodyText(squash);
  if (squashFile.error) {
    console.error(squashFile.error);
    return 1;
  }
  const failures = checkSources([
    { label: "PR body", text: bodyFile.text },
    { label: "commit messages", text: commitsFile.text },
    { label: "squash body", text: squashFile.text },
  ]);
  failures.push(...agentsFailures(authoredPrBody(bodyFile.text)));
  if (failures.length > 0) {
    for (const line of failures) {
      console.error(line);
    }
    return 1;
  }
  return 0;
}

module.exports = {
  authoredPrBody,
  hitsIn,
  isCoAuthoredByLine,
  stripCoAuthoredBy,
  checkSources,
  explicitSquashBody,
  main,
};

if (require.main === module) {
  process.exitCode = main();
}
