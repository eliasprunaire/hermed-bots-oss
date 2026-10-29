"use strict";

const net = require("node:net");
const os = require("node:os");

function entries() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const entry of list || []) if (!entry.internal) out.push({ ...entry, name });
  }
  return out;
}

// A non-loopback address of the host, read at run time, never written down.
function outsideAddress() {
  const found = entries().find((e) => e.family === "IPv4");
  return found ? found.address : null;
}

// A scoped (interface-local) address with its zone, or null when there is none.
function scopedAddress() {
  const found = entries().find((e) => e.family === "IPv6" && e.scopeid > 0);
  return found ? `${found.address.split("%")[0]}%${found.name}` : null;
}

// The wildcard address, as the system reports it for a listener with no host.
async function wildcardAddress() {
  const probe = net.createServer();
  await new Promise((resolve) => probe.listen(0, resolve));
  const { address } = probe.address();
  await new Promise((resolve) => probe.close(resolve));
  return address;
}

// The IPv6 loopback address as the system reports it, or null when IPv6 is off.
function loopbackV6() {
  for (const list of Object.values(os.networkInterfaces())) {
    for (const entry of list || []) if (entry.internal && entry.family === "IPv6") return entry.address;
  }
  return null;
}

module.exports = { loopbackV6, outsideAddress, scopedAddress, wildcardAddress };
