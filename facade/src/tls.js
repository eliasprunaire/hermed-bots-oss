"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");
const tls = require("node:tls");
const { spawnSync } = require("node:child_process");

const CA_DAYS = 3650;
const SERVER_DAYS = 365;

function openssl(args, input) {
  const result = spawnSync("openssl", args, { encoding: "utf8", input });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`openssl ${args[0]} failed`);
  return result.stdout;
}

// Base64 SHA-256 of the SubjectPublicKeyInfo. It survives a certificate renewal that keeps the key.
function spkiPin(certPem) {
  const der = new crypto.X509Certificate(certPem).publicKey.export({ type: "spki", format: "der" });
  return crypto.createHash("sha256").update(der).digest("base64");
}

function sanEntry(host) {
  return net.isIP(host) ? `IP:${host}` : `DNS:${host}`;
}

// Dedicated internal CA plus one server certificate. The CA key stays in `dir` on the host.
// A renewal reuses the server key when `reuseKey` is set, so the pin does not change.
function generatePki({ dir, hosts = ["localhost", "127.0.0.1"], reuseKey = true }) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = (name) => path.join(dir, name);
  const write = (name, text) => fs.writeFileSync(file(name), text, { mode: 0o600 });

  if (!fs.existsSync(file("ca.key")) || !fs.existsSync(file("ca.crt"))) {
    write("ca.key", openssl(["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"]));
    write(
      "ca.crt",
      openssl([
        "req", "-x509", "-new", "-key", file("ca.key"), "-sha256", "-days", String(CA_DAYS),
        "-subj", "/CN=Hermed Bots Facade CA",
        "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign",
      ]),
    );
  }

  if (!reuseKey || !fs.existsSync(file("server.key"))) {
    write("server.key", openssl(["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"]));
  }
  const csr = openssl(["req", "-new", "-key", file("server.key"), "-subj", "/CN=Hermed Bots Facade"]);
  write("server.csr", csr);
  write(
    "server.ext",
    [
      "basicConstraints=critical,CA:FALSE",
      "keyUsage=critical,digitalSignature",
      "extendedKeyUsage=serverAuth",
      `subjectAltName=${hosts.map(sanEntry).join(",")}`,
      "",
    ].join("\n"),
  );
  write(
    "server.crt",
    openssl([
      "x509", "-req", "-in", file("server.csr"), "-CA", file("ca.crt"), "-CAkey", file("ca.key"),
      "-CAcreateserial", "-sha256", "-days", String(SERVER_DAYS), "-extfile", file("server.ext"),
    ]),
  );
  fs.rmSync(file("server.csr"), { force: true });
  fs.rmSync(file("server.ext"), { force: true });
  fs.rmSync(file("ca.srl"), { force: true });

  const serverCert = fs.readFileSync(file("server.crt"), "utf8");
  return {
    caCert: fs.readFileSync(file("ca.crt"), "utf8"),
    serverCert,
    serverKey: fs.readFileSync(file("server.key"), "utf8"),
    pin: spkiPin(serverCert),
  };
}

// Client side. Trust is the dedicated CA alone (never the system roots), and the server key
// must match the pinned SPKI hash. Hand the result to https.request, tls.connect or an Agent.
function pinnedClientOptions({ caPem, pin }) {
  return {
    ca: caPem,
    minVersion: "TLSv1.3",
    checkServerIdentity(host, cert) {
      const failure = tls.checkServerIdentity(host, cert);
      if (failure) return failure;
      const actual = crypto
        .createHash("sha256")
        .update(new crypto.X509Certificate(cert.raw).publicKey.export({ type: "spki", format: "der" }))
        .digest("base64");
      const a = Buffer.from(actual);
      const b = Buffer.from(String(pin));
      if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
        return new Error("server key does not match the pinned key");
      }
      return undefined;
    },
  };
}

module.exports = { generatePki, pinnedClientOptions, spkiPin };
