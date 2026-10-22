"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const [app, tools, output] = process.argv.slice(2).map(value => path.resolve(value));
assert.ok(app && tools && output, "Usage: check-appcast.js <unsigned-built-app> <sparkle-bin> <new-output-directory>");
fs.mkdirSync(output);
const updates = path.join(output, "updates");
fs.mkdirSync(updates);
const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
const seed = Buffer.from(privateKey.export({ format: "jwk" }).d, "base64url").toString("base64");
const publicValue = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url").toString("base64");

function run(command, args, input) {
  const result = spawnSync(command, args, { encoding: "utf8", input });
  assert.equal(result.status, 0, `${path.basename(command)}: ${(result.stdout + result.stderr).replaceAll(seed, "****")}`);
  return result.stdout;
}

for (const version of ["0.1.0", "0.1.1"]) {
  const copy = path.join(output, version, "HermedBots.app");
  fs.mkdirSync(path.dirname(copy));
  run("ditto", [app, copy]);
  const plist = path.join(copy, "Contents/Info.plist");
  for (const [key, value] of Object.entries({
    CFBundleVersion: version, CFBundleShortVersionString: version, SUPublicEDKey: publicValue,
    SUFeedURL: "https://example.invalid/appcast.xml",
  })) run("/usr/libexec/PlistBuddy", ["-c", `Set :${key} ${value}`, plist]);
  run("codesign", ["--force", "--deep", "--sign", "-", copy]);
  run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", copy, path.join(updates, `HermedBots-${version}.zip`)]);
}
run(path.join(tools, "generate_appcast"), ["--ed-key-file", "-", "--download-url-prefix", "https://example.invalid/", updates], seed);
const feed = path.join(updates, "appcast.xml");
run(path.join(tools, "sign_update"), ["--verify", "--ed-key-file", "-", feed], seed);
const xml = fs.readFileSync(feed, "utf8");
for (const version of ["0.1.0", "0.1.1"]) assert.ok(xml.includes(`<sparkle:version>${version}</sparkle:version>`));
const enclosures = [...xml.matchAll(/<enclosure\s+([^>]+)\/?\s*>/g)].filter(([, attributes]) => !attributes.includes("sparkle:deltaFrom"));
assert.equal(enclosures.length, 2);
for (const [, attributes] of enclosures) {
  const file = /url="[^"]*\/(HermedBots-[^"]+\.zip)"/.exec(attributes)[1];
  const signature = /sparkle:edSignature="([^"]+)"/.exec(attributes)[1];
  assert.ok(crypto.verify(null, fs.readFileSync(path.join(updates, file)), publicKey, Buffer.from(signature, "base64")));
}
const tampered = path.join(output, "tampered.xml");
fs.writeFileSync(tampered, xml.replace("0.1.1", "0.1.2"));
const rejected = spawnSync(path.join(tools, "sign_update"), ["--verify", "--ed-key-file", "-", tampered], { encoding: "utf8", input: seed });
assert.notEqual(rejected.status, 0);
fs.writeFileSync(path.join(output, "result.json"), JSON.stringify({
  versions: ["0.1.0", "0.1.1"], signedFeed: true, archiveSignatures: enclosures.length,
  tamperedFeedRejected: true, appleSigned: false, appLaunched: false,
}, null, 2) + "\n");
console.log("Sparkle CLI: signed feed accepted, 2 archive signatures accepted, tampered feed rejected. No app launched; ad hoc signatures only.");
