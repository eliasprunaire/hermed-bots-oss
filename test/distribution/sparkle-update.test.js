"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");

// Flat key/value pairs of the app's Info.plist: raw value tokens such as <true/> or <string>x</string>
function plistEntries(file) {
  const text = fs.readFileSync(file, "utf8");
  const entries = {};
  for (const [, key, value] of text.matchAll(/<key>([^<]+)<\/key>\s*(<true\/>|<false\/>|<string>[^<]*<\/string>)/g)) entries[key] = value;
  return entries;
}

test("the app bundle carries the Sparkle feed, the public key and the signed-feed switches", () => {
  const plist = plistEntries("Config/Info.plist");
  // The release script fills these two build settings at archive time
  assert.equal(plist.SUFeedURL, "<string>$(SPARKLE_FEED_URL)</string>");
  assert.equal(plist.SUPublicEDKey, "<string>$(SPARKLE_PUBLIC_KEY)</string>");
  for (const key of ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableAutomaticChecks"]) {
    assert.equal(plist[key], "<true/>", key);
  }
});
