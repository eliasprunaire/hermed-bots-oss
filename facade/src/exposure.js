"use strict";

const net = require("node:net");
const os = require("node:os");
const { isLoopbackHost } = require("./config");

const CLOSED = new Set(["ECONNREFUSED", "ECONNRESET", "EHOSTUNREACH", "ENETUNREACH", "EADDRNOTAVAIL", "ENETDOWN", "ETIMEDOUT"]);

// "open" when the port answers, "closed" when it is refused, dropped or unroutable, "unknown" when
// the probe itself failed in a way that proves nothing. Unknown counts against the host.
function probe(host, port, timeoutMs) {
  return new Promise((resolve) => {
    let socket;
    const done = (value) => {
      if (socket) socket.destroy();
      resolve(value);
    };
    try {
      socket = net.connect({ host, port });
    } catch {
      resolve("unknown");
      return;
    }
    socket.setTimeout(timeoutMs, () => done("closed"));
    socket.once("connect", () => done("open"));
    socket.once("error", (err) => done(CLOSED.has(err.code) ? "closed" : "unknown"));
  });
}

// Every address that is not on a loopback interface, whatever its family or scope. A scoped
// address (an interface-local one) can only be reached with its zone, so the zone is part of the target.
function targets(interfaces) {
  const out = [];
  for (const [name, entries] of Object.entries(interfaces)) {
    for (const entry of entries || []) {
      if (entry.internal || isLoopbackHost(entry.address)) continue;
      const scoped = entry.family === "IPv6" && entry.scopeid > 0 && !entry.address.includes("%");
      out.push(scoped ? `${entry.address}%${name}` : entry.address);
    }
  }
  return out;
}

// Is the Hermes port reachable on the host from anywhere but the loopback? A yes means a
// device could skip the facade and meet Hermes directly. A configured host that is not a
// loopback address, a wildcard included, fails at once. Only counts are reported.
async function checkExposure({ host, port, timeoutMs = 500, interfaces = os.networkInterfaces(), connect = probe }) {
  const loopbackHost = isLoopbackHost(host);
  const list = targets(interfaces);
  const results = await Promise.all(list.map((target) => connect(target, port, timeoutMs)));
  const exposedOn = results.filter((r) => r === "open").length;
  const unverified = results.filter((r) => r === "unknown").length;
  return {
    ok: loopbackHost && exposedOn === 0 && unverified === 0,
    loopbackHost,
    interfacesChecked: list.length,
    exposedOn,
    unverified,
  };
}

module.exports = { checkExposure, targets };
