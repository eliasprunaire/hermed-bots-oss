"use strict";

const net = require("node:net");
const os = require("node:os");
const { isLoopbackHost } = require("./config");

function reachable(host, port, timeoutMs) {
  return new Promise((resolve) => {
    const socket = net.connect({ host, port });
    const done = (value) => {
      socket.destroy();
      resolve(value);
    };
    socket.setTimeout(timeoutMs, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

function nonLoopbackAddresses() {
  const out = [];
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.internal) continue;
      if (entry.family === "IPv6" && entry.address.toLowerCase().startsWith("fe80")) continue;
      out.push(entry.address);
    }
  }
  return out;
}

// Is the Hermes port reachable on this machine from anywhere but the loopback? A yes means a
// device could skip the facade and meet Hermes directly. Counts only: addresses are never reported.
async function checkExposure({ host, port, timeoutMs = 500 }) {
  const addresses = nonLoopbackAddresses();
  const results = await Promise.all(addresses.map((address) => reachable(address, port, timeoutMs)));
  const exposedOn = results.filter(Boolean).length;
  const loopbackHost = isLoopbackHost(host);
  return {
    ok: loopbackHost && exposedOn === 0,
    loopbackHost,
    interfacesChecked: addresses.length,
    exposedOn,
  };
}

module.exports = { checkExposure };
