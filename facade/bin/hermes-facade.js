#!/usr/bin/env node
"use strict";

const path = require("node:path");
const { fromEnv } = require("../src/config");
const { checkExposure } = require("../src/exposure");
const { createFacade } = require("../src/server");
const { Store } = require("../src/store");
const { generatePki } = require("../src/tls");

const USAGE = `Usage: hermes-facade <command>

  init-tls [--host NAME]...   create the internal CA and the server certificate, print the pin
  serve                       start the facade (TLS only)
  enroll [--role admin|normal]  print a one-use enrollment code (valid 5 minutes)
  devices                     list devices
  revoke <device-id>          revoke one device now
  check-exposure              fail when Hermes is reachable beyond the loopback

Settings come from the environment: HERMES_FACADE_STATE_DIR (required), HERMES_FACADE_TLS_DIR,
HERMES_FACADE_LISTEN_HOST, HERMES_FACADE_LISTEN_PORT, HERMES_FACADE_UPSTREAM_HOST,
HERMES_FACADE_UPSTREAM_PORT, HERMES_FACADE_UPSTREAM_TOKEN or HERMES_FACADE_UPSTREAM_TOKEN_FILE,
HERMES_FACADE_RATE_LIMIT_PER_MINUTE.
`;

function option(args, name) {
  const values = [];
  for (let i = 0; i < args.length; i++) if (args[i] === name && args[i + 1]) values.push(args[i + 1]);
  return values;
}

function stateDir(env) {
  if (!env.HERMES_FACADE_STATE_DIR) throw new Error("HERMES_FACADE_STATE_DIR is required");
  return path.resolve(env.HERMES_FACADE_STATE_DIR);
}

function tlsDir(env) {
  return env.HERMES_FACADE_TLS_DIR ? path.resolve(env.HERMES_FACADE_TLS_DIR) : path.join(stateDir(env), "tls");
}

async function main(argv, env = process.env, out = process.stdout) {
  const [command, ...args] = argv;
  const print = (text) => out.write(`${text}\n`);
  switch (command) {
    case "init-tls": {
      const hosts = option(args, "--host");
      const pki = generatePki({ dir: tlsDir(env), hosts: hosts.length ? hosts : ["localhost", "127.0.0.1"] });
      print(`pin ${pki.pin}`);
      print("ca.crt is the only trust anchor to hand to the clients. Give them the pin out of band.");
      return 0;
    }
    case "serve": {
      const facade = createFacade(fromEnv(env));
      const port = await facade.start();
      print(`facade listening (TLS) on port ${port}`);
      const stop = () => facade.close().finally(() => process.exit(0));
      process.once("SIGINT", stop);
      process.once("SIGTERM", stop);
      return null;
    }
    case "enroll": {
      const role = option(args, "--role")[0] || "normal";
      const store = new Store({ file: path.join(stateDir(env), "state.json") });
      const made = store.createEnrollment({ role, createdBy: "host" });
      print(`code ${made.code}`);
      print(`role ${made.role}`);
      print(`expires ${new Date(made.expiresAt).toISOString()}`);
      return 0;
    }
    case "devices": {
      const store = new Store({ file: path.join(stateDir(env), "state.json") });
      for (const d of store.list()) {
        print(`${d.id}\t${d.role}\t${d.revokedAt ? "revoked" : "active"}\t${d.name}`);
      }
      return 0;
    }
    case "revoke": {
      const store = new Store({ file: path.join(stateDir(env), "state.json") });
      const done = store.revoke(args[0]);
      print(done ? `revoked ${done.id}` : "unknown device");
      return done ? 0 : 1;
    }
    case "check-exposure": {
      const result = await checkExposure({
        host: env.HERMES_FACADE_UPSTREAM_HOST || "127.0.0.1",
        port: Number(env.HERMES_FACADE_UPSTREAM_PORT || 9119),
      });
      print(result.ok ? "PASS the Hermes port is reachable on the loopback only" : `FAIL loopback host ${result.loopbackHost}, reachable on ${result.exposedOn} non-loopback interface(s)`);
      return result.ok ? 0 : 1;
    }
    default:
      out.write(USAGE);
      return command ? 2 : 0;
  }
}

if (require.main === module) {
  main(process.argv.slice(2)).then(
    (code) => {
      if (code !== null) process.exitCode = code;
    },
    (err) => {
      process.stderr.write(`${err.message}\n`);
      process.exitCode = 1;
    },
  );
}

module.exports = { main };
