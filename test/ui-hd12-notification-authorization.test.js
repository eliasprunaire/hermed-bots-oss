"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const ROOT = join(__dirname, "..");
const LOOP_PAUSE_FAKE = "Notification de test.";

function read(rel) {
  return readFileSync(join(ROOT, rel), "utf8");
}

function firstBlock(source, marker) {
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, marker);
  const open = source.indexOf("{", start);
  assert.notEqual(open, -1, marker);
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    const char = source[index];
    if (char === "{") depth += 1;
    else if (char === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  assert.fail(marker);
}

function producedAuthorizationLine(pauseSource) {
  const post = firstBlock(pauseSource, "func post(cause");
  const testMode = post.search(/HV_TEST_MODE/);
  if (testMode === -1) return null;
  const un = post.indexOf("UNUserNotificationCenter", testMode);
  const region = un === -1 ? post.slice(testMode) : post.slice(testMode, un);
  const selfRef = /return Self\.(\w+)/.exec(region);
  if (selfRef) {
    const def = new RegExp(`static let ${selfRef[1]} = "([^"]+)"`).exec(pauseSource);
    return def ? def[1] : null;
  }
  const quoted = /"([^"]*Autorisation[^"]*)"/.exec(region);
  return quoted ? quoted[1] : null;
}

test("hd12-notification-authorization montre l'autorisation déterministe, pas hd12-loop-pause", () => {
  const pause = read("HermedBots/Banners/LoopPauseNotifications.swift");
  const env = read("HermedBots/App/AppEnvironment.swift");
  const errors = read("HermedBotsUITests/Errors.swift");
  const native = firstBlock(errors, "final class NativeNotifications");

  assert.match(env, /static let testPauseNotification = "Notification de test\."/);
  const auth = producedAuthorizationLine(pause);
  assert.notEqual(auth, null, "aucun faux d'autorisation avant UNUserNotificationCenter");
  assert.match(auth, /Autorisation des notifications/);
  assert.notEqual(auth, LOOP_PAUSE_FAKE);

  const captureAt = native.indexOf('HVShot.capture("hd12-notification-authorization"');
  assert.notEqual(captureAt, -1);
  const before = native.slice(0, captureAt);
  assert.match(before, /hd\.loop\.notification/);
  assert.equal(native.includes("XCTSkip"), false, "la capture ne dépend plus de l'autorisation macOS");
  assert.equal(native.includes("remise par macOS"), false);
  assert.match(native, new RegExp(auth.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(native, /nativePauseNotification = true/);
});

test("sans le faux, la ligne d'autorisation retombe sur le texte de loop-pause", () => {
  const withoutFake = [
    "func post(cause: LoopGuard.Cause) async -> String {",
    "    let center = UNUserNotificationCenter.current()",
    "    return \"Notification remise par macOS.\"",
    "}",
  ].join("\n");
  assert.equal(producedAuthorizationLine(withoutFake), null);
});

test("AppEnvironment et HD12Harness décrivent le faux d'autorisation, pas la voie native en mode test", () => {
  const env = read("HermedBots/App/AppEnvironment.swift");
  const harness = read("HermedBotsUITests/HD12Harness.swift");
  const skipped = read("docs/spike/issue57/skipped-tests.md");
  assert.equal(/garde `UNUserNotificationCenter`/.test(env), false);
  assert.equal(/l'app garde `UNUserNotificationCenter`/.test(harness), false);
  assert.match(env, /faux d'autorisation|court-circuite/);
  assert.match(harness, /faux d'autorisation/);
  assert.equal(/\| `NativeNotifications\/testLoopPauseNotificationDelivery` \|/.test(skipped), false);
  assert.match(skipped, /n'est plus ignorée/);
  assert.match(skipped, /42 tests ignorés/);
});
