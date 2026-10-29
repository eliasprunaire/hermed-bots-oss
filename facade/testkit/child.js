"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { pki } = require("./stack");

const BIN = path.resolve(__dirname, "../bin/hermes-facade.js");

// The real CLI as a child process, so a test can kill it the way a crash would.
function startChild({ dir, hermes }) {
  const material = pki();
  const tlsDir = path.join(dir, "tls");
  fs.mkdirSync(tlsDir, { recursive: true });
  fs.writeFileSync(path.join(tlsDir, "server.key"), material.serverKey, { mode: 0o600 });
  fs.writeFileSync(path.join(tlsDir, "server.crt"), material.serverCert);
  const child = spawn(process.execPath, [BIN, "serve"], {
    env: {
      PATH: process.env.PATH,
      HERMES_FACADE_STATE_DIR: dir,
      HERMES_FACADE_LISTEN_PORT: "0",
      HERMES_FACADE_UPSTREAM_PORT: String(hermes.port),
      HERMES_FACADE_UPSTREAM_TOKEN: hermes.token,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let exited = false;
  child.once("exit", () => {
    exited = true;
  });
  return new Promise((resolve, reject) => {
    let out = "";
    child.stdout.on("data", (chunk) => {
      out += chunk;
      const match = /on port (\d+)/.exec(out);
      if (match) {
        resolve({
          port: Number(match[1]),
          pid: child.pid,
          kill: () =>
            new Promise((done) => {
              if (exited) return done();
              child.once("exit", done);
              return child.kill("SIGKILL");
            }),
        });
      }
    });
    child.once("exit", (code) => reject(new Error(`facade child exited early (${code})`)));
    setTimeout(() => reject(new Error("facade child did not start")), 10_000).unref();
  });
}

module.exports = { startChild };
