"use strict";

const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

const MARKER_NAME = ".hermed-bots-disposable";
const MARKER_TEXT = "disposable test instance, writes allowed\n";

function readStatus({ port, token }) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: "127.0.0.1", port, path: "/api/status", headers: { "x-hermes-session-token": token }, timeout: 5000 }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
        } catch (err) {
          reject(err);
        }
      });
    });
    req.on("timeout", () => req.destroy(new Error("status timeout")));
    req.on("error", reject);
  });
}

// A write is allowed only on an instance the operator marked as disposable, and only when the
// running process proves it uses that marked data directory. The check reads and never writes.
async function assertDisposable({ port, token, home, status = readStatus }) {
  if (!home) throw new Error("HERMES_TEST_HOME is required: the data directory of the disposable test instance");
  const root = fs.realpathSync(home);
  const marker = path.join(root, MARKER_NAME);
  let text;
  try {
    text = fs.readFileSync(marker, "utf8");
  } catch {
    throw new Error(`refusing to write: ${MARKER_NAME} is missing in the data directory`);
  }
  if (text !== MARKER_TEXT) throw new Error(`refusing to write: ${MARKER_NAME} does not hold the expected text`);
  const reported = await status({ port, token });
  if (!reported || typeof reported.hermes_home !== "string") {
    throw new Error("refusing to write: the instance does not report its data directory");
  }
  let running;
  try {
    running = fs.realpathSync(reported.hermes_home);
  } catch {
    throw new Error("refusing to write: the data directory the instance reports does not exist here");
  }
  if (running !== root) throw new Error("refusing to write: the running instance does not use the marked data directory");
  return true;
}

module.exports = { MARKER_NAME, MARKER_TEXT, assertDisposable, readStatus };
