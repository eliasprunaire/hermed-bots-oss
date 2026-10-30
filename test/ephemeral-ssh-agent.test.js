"use strict";

const assert = require("node:assert/strict");
const { generateKeyPairSync, randomBytes } = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");
const {
  chmodSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { createServer } = require("node:net");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const TUNNEL = join(ROOT, "HermedBots/Transport/SSHTunnel.swift");
const AGENT = join(ROOT, "HermedBots/Transport/EphemeralSSHAgent.swift");

function encodeString(buf) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(buf.length);
  return Buffer.concat([len, buf]);
}

function opensshEd25519Private(seed, pub, comment) {
  const keytype = Buffer.from("ssh-ed25519");
  const pubBlob = Buffer.concat([encodeString(keytype), encodeString(pub)]);
  const priv = Buffer.concat([seed, pub]);
  const check = randomBytes(4);
  const inner = Buffer.concat([
    check,
    check,
    encodeString(keytype),
    encodeString(pub),
    encodeString(priv),
    encodeString(Buffer.from(comment)),
  ]);
  const padLen = (8 - (inner.length % 8)) % 8;
  const pad = Buffer.from(Array.from({ length: padLen }, (_, i) => i + 1));
  const nkeys = Buffer.alloc(4);
  nkeys.writeUInt32BE(1);
  const body = Buffer.concat([
    Buffer.from("openssh-key-v1\0"),
    encodeString(Buffer.from("none")),
    encodeString(Buffer.from("none")),
    encodeString(Buffer.alloc(0)),
    nkeys,
    encodeString(pubBlob),
    encodeString(Buffer.concat([inner, pad])),
  ]);
  const wrapped = body.toString("base64").match(/.{1,70}/g).join("\n");
  return `-----BEGIN OPENSSH PRIVATE KEY-----\n${wrapped}\n-----END OPENSSH PRIVATE KEY-----\n`;
}

function fixtureKey() {
  const pair = generateKeyPairSync("ed25519");
  const pub = pair.publicKey.export({ type: "spki", format: "der" }).subarray(-32);
  const seed = pair.privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32);
  return opensshEd25519Private(seed, pub, "fixture");
}

function waitFor(predicate, timeoutMs) {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (predicate()) return resolve();
      if (Date.now() - start > timeoutMs) return reject(new Error("timeout"));
      setTimeout(tick, 20);
    };
    tick();
  });
}

function classify(stderr) {
  const text = String(stderr);
  if (
    text.includes("Could not open a connection to your authentication agent") ||
    text.includes("Error connecting to agent")
  ) {
    return "missingAgent";
  }
  if (text.includes("The agent has no identities")) return "missingKey";
  if (text.includes("Permission denied")) return "wrongKey";
  return "unreachable";
}

function banner(kind) {
  if (kind === "missingAgent") return "L'agent SSH est absent. Démarre l'agent, puis réessaie.";
  if (kind === "missingKey") return "La clé SSH n'est pas chargée dans l'agent. Charge une identité dans l'agent, puis réessaie.";
  return "";
}

test("an empty key command does not construct a command private key source", () => {
  const app = readFileSync(join(ROOT, "HermedBots/App/AppModel.swift"), "utf8");
  const start = app.indexOf("private func ephemeralKeySource");
  assert.notEqual(start, -1);
  const fn = app.slice(start, app.indexOf("private static func apiMessage", start));
  const afterEndif = fn.slice(fn.lastIndexOf("#endif"));
  const nilAt = afterEndif.indexOf("return nil");
  const commandAt = afterEndif.indexOf("CommandPrivateKeySource");
  assert.ok(nilAt !== -1 && commandAt !== -1 && nilAt < commandAt, afterEndif);
});

test("app Swift starts ssh-agent, loads the key on stdin, and never writes it", () => {
  const agent = readFileSync(AGENT, "utf8");
  const tunnel = readFileSync(TUNNEL, "utf8");
  assert.match(agent, /\/usr\/bin\/ssh-agent/);
  assert.match(agent, /"-D", "-a"/);
  assert.match(agent, /\/usr\/bin\/ssh-add/);
  assert.match(agent, /"-t".*"-"/);
  assert.match(agent, /stdin: data/);
  assert.equal(/IdentityFile|key\.pub/i.test(agent), false);
  assert.match(tunnel, /withIdentityAgent/);
  assert.match(tunnel, /IdentityAgent=/);
  assert.match(tunnel, /teardownEphemeral/);
});

test("a missing agent is classified before publickey", () => {
  const tunnel = readFileSync(TUNNEL, "utf8");
  const classification = readFileSync(
    join(ROOT, "Packages/HermesAdapter/Sources/AppSettings/SSHExitClassification.swift"),
    "utf8",
  );
  const start = classification.indexOf("public static func kind");
  const classifyFn = classification.slice(start);
  assert.ok(classifyFn.indexOf("Error connecting to agent") < classifyFn.indexOf("Permission denied"));
  assert.match(tunnel, /case missingAgent/);
  assert.match(tunnel, /case missingKey/);
  assert.match(tunnel, /L'agent SSH est absent/);
  assert.match(tunnel, /La clé SSH n'est pas chargée dans l'agent/);
  assert.equal(classify("Error connecting to agent: No such file or directory"), "missingAgent");
  assert.equal(classify("The agent has no identities."), "missingKey");
  assert.equal(classify("user@example.invalid: Permission denied (publickey)."), "wrongKey");
  assert.equal(banner("missingAgent").includes("publickey"), false);
  assert.equal(banner("missingKey").includes("publickey"), false);
});

test("the temporary agent authenticates a local ssh double then disappears", async () => {
  const pem = fixtureKey();
  const dir = mkdtempSync(join(tmpdir(), "hb-agent-"));
  chmodSync(dir, 0o700);
  const sock = join(dir, "a");
  const agent = spawn("/usr/bin/ssh-agent", ["-D", "-a", sock], {
    stdio: ["ignore", "ignore", "ignore"],
  });
  try {
    await waitFor(() => existsSync(sock), 2000);
    const add = spawnSync("/usr/bin/ssh-add", ["-t", "30", "-"], {
      env: { PATH: "/usr/bin:/bin", SSH_AUTH_SOCK: sock },
      input: pem,
      encoding: "utf8",
    });
    assert.equal(add.status, 0, add.stderr);
    assert.equal(add.stdout.includes("BEGIN"), false);
    assert.equal(readdirSync(dir).join(","), "a");
    const list = spawnSync("/usr/bin/ssh-add", ["-l"], {
      env: { PATH: "/usr/bin:/bin", SSH_AUTH_SOCK: sock },
      encoding: "utf8",
    });
    assert.equal(list.status, 0, list.stderr);
    assert.match(list.stdout, /ED25519/);

    const localPort = await new Promise((resolve, reject) => {
      const probe = createServer();
      probe.listen(0, "127.0.0.1", () => {
        const port = probe.address().port;
        probe.close(() => resolve(port));
      });
      probe.on("error", reject);
    });

    const doublePath = join(dir, "ssh-double");
    writeFileSync(
      doublePath,
      [
        "#!/bin/sh",
        "agent=\"\"",
        "localport=\"\"",
        "prev=\"\"",
        "for arg in \"$@\"; do",
        "  if [ \"$prev\" = \"-o\" ]; then",
        "    case \"$arg\" in IdentityAgent=*) agent=\"${arg#IdentityAgent=}\" ;; esac",
        "  fi",
        "  if [ \"$prev\" = \"-L\" ]; then",
        "    localport=$(printf '%s' \"$arg\" | awk -F: '{print $2}')",
        "  fi",
        "  prev=\"$arg\"",
        "done",
        "if [ -z \"$agent\" ]; then",
        "  printf '%s\\n' 'user@example.invalid: Permission denied (publickey).' >&2",
        "  exit 255",
        "fi",
        "if ! SSH_AUTH_SOCK=\"$agent\" /usr/bin/ssh-add -l >/dev/null 2>&1; then",
        "  printf '%s\\n' 'Error connecting to agent: No such file or directory' >&2",
        "  exit 255",
        "fi",
        "/usr/bin/python3 -c 'import socket,sys; p=int(sys.argv[1]); s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((\"127.0.0.1\",p)); s.listen(1); s.settimeout(5); c,_=s.accept(); c.close()' \"$localport\"",
      ].join("\n"),
      { mode: 0o755 },
    );

    const child = spawn(
      doublePath,
      [
        "-N",
        "-T",
        "-o",
        `IdentityAgent=${sock}`,
        "-L",
        `127.0.0.1:${localPort}:127.0.0.1:8642`,
        "lab.invalid",
      ],
      { stdio: ["ignore", "ignore", "pipe"], env: { PATH: "/usr/bin:/bin" } },
    );
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    try {
      await waitFor(() => {
        const sockClient = spawnSync(
          process.execPath,
          [
            "-e",
            `require("net").connect({host:"127.0.0.1",port:${localPort}},()=>process.exit(0)).on("error",()=>process.exit(1))`,
          ],
        );
        return sockClient.status === 0;
      }, 5000);
      assert.equal(stderr.includes("publickey"), false, stderr);
    } finally {
      child.kill("SIGKILL");
    }

    agent.kill("SIGKILL");
    await waitFor(() => agent.exitCode !== null || agent.signalCode === "SIGKILL", 1000);
    const after = spawnSync("/usr/bin/ssh-add", ["-l"], {
      env: { PATH: "/usr/bin:/bin", SSH_AUTH_SOCK: sock },
      encoding: "utf8",
    });
    assert.equal(after.status, 2);
    assert.equal(classify(after.stderr), "missingAgent");
    assert.equal(banner(classify(after.stderr)).includes("publickey"), false);
  } finally {
    agent.kill("SIGKILL");
    rmSync(dir, { recursive: true, force: true });
  }
});

test("ssh-add names a missing agent instead of publickey", () => {
  const missing = spawnSync("/usr/bin/ssh-add", ["-l"], {
    env: { PATH: "/usr/bin:/bin", SSH_AUTH_SOCK: "/tmp/missing-agent.invalid" },
    encoding: "utf8",
  });
  assert.equal(missing.status, 2);
  assert.equal(classify(missing.stderr), "missingAgent");
  assert.equal(missing.stderr.includes("publickey"), false);
});
