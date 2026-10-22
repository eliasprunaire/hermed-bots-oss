"use strict";

const fs = require("node:fs");

function versionFromTag(tag) {
  const match = /^v(0|[1-9]\d{0,3})\.(0|[1-9]\d?)\.(0|[1-9]\d?)$/.exec(tag);
  if (!match || match[0] !== tag) throw new Error("Expected final tag vX.Y.Z within CFBundleVersion limits");
  return match.slice(1).join(".");
}

function assertReleaseOrder(tag, latest) {
  const next = versionFromTag(tag).split(".").map(Number);
  if (!latest) return;
  const previous = versionFromTag(latest).split(".").map(Number);
  const difference = next.map((part, index) => part - previous[index]).find(part => part !== 0);
  if (difference < 0) throw new Error("Refusing to replace a newer release");
}

function validRepository(repository) {
  return /^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(repository || "") && !/\s/.test(repository) &&
    repository.toLowerCase() !== "eliasprunaire/hermed-bots";
}

// Homebrew resolves owner/tap to the owner/homebrew-tap repository
function tapRepository(repository) {
  if (!validRepository(repository)) throw new Error("Invalid distribution repository");
  return `${repository.split("/")[0]}/homebrew-tap`;
}

function releaseReadiness(env) {
  const required = [
    "APPLE_TEAM_ID", "DEVELOPER_ID_P12", "DEVELOPER_ID_P12_PASSWORD",
    "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "SPARKLE_PRIVATE_KEY",
    "SPARKLE_PUBLIC_KEY", "DISTRIBUTION_TOKEN", "DISTRIBUTION_REPOSITORY",
  ];
  const missing = required.filter(key => !env[key]?.trim());
  if (env.DISTRIBUTION_APPROVED !== "true") missing.push("DISTRIBUTION_APPROVED=true");
  if (env.DISTRIBUTION_REPOSITORY && !validRepository(env.DISTRIBUTION_REPOSITORY)) missing.push("valid DISTRIBUTION_REPOSITORY");
  if (env.SPARKLE_PUBLIC_KEY && (env.SPARKLE_PUBLIC_KEY.length !== 44 || !/^[A-Za-z0-9+/]{43}=$/.test(env.SPARKLE_PUBLIC_KEY))) missing.push("valid SPARKLE_PUBLIC_KEY");
  return { ready: missing.length === 0, missing };
}

function renderCask(tag, sha256, repository) {
  const version = versionFromTag(tag);
  if (sha256.length !== 64 || !/^[a-f0-9]{64}$/.test(sha256) || !validRepository(repository)) throw new Error("Invalid cask archive hash or repository");
  return `cask "hermed-bots" do
  version "${version}"
  sha256 "${sha256}"

  url "https://github.com/${repository}/releases/download/v#{version}/HermedBots-#{version}.zip"
  name "Hermed Bots"
  desc "Native client for Hermes bots"
  homepage "https://github.com/${repository}"

  auto_updates true
  depends_on macos: :golden_gate

  app "HermedBots.app"
end
`;
}

if (require.main === module) {
  const [command, ...args] = process.argv.slice(2);
  try {
    if (command === "version") console.log(versionFromTag(args[0]));
    else if (command === "order") assertReleaseOrder(...args);
    else if (command === "preflight") {
      const result = releaseReadiness(process.env);
      console.log(result.ready ? "Distribution ready" : `Distribution skipped: ${result.missing.join(", ")}`);
      if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `ready=${result.ready}\n`);
    } else if (command === "cask") process.stdout.write(renderCask(...args));
    else if (command === "tap") console.log(tapRepository(args[0]));
    else throw new Error("Usage: distribution.js version <tag> | preflight | cask <tag> <sha256> <owner/repo> | tap <owner/repo>");
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = { versionFromTag, releaseReadiness, renderCask, assertReleaseOrder, tapRepository };
