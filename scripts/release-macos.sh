#!/bin/bash
set -euo pipefail
set +x

cd "$(dirname "$0")/.."
tag=${1:?Expected vX.Y.Z}
version=$(node scripts/distribution.js version "$tag")
# Credentials are inspected only for presence until an ephemeral CI runner owns the build
ready=$(node -e 'process.stdout.write(String(require("./scripts/distribution.js").releaseReadiness(process.env).ready))')
if [ "$ready" != true ]; then
  node scripts/distribution.js preflight
  exit 0
fi
if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_OS:-}" != macOS ]; then
  echo 'Signing is restricted to an ephemeral GitHub macOS runner' >&2
  exit 1
fi
work="$PWD/.audit/distribution"
mkdir -p "$work/out"
stages="$work/stages.txt"
: > "$stages"
private=$(mktemp -d "$RUNNER_TEMP/hermed-signing.XXXXXX")
keychain="$private/signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$private"
}
trap cleanup EXIT
umask 077
printf '%s' "$DEVELOPER_ID_P12" | base64 --decode > "$private/developer.p12"
printf '%s' "$ASC_KEY_P8" > "$private/AuthKey.p8"
keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$private/developer.p12" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
feed="https://github.com/$DISTRIBUTION_REPOSITORY/releases/latest/download/appcast.xml"
xcodebuild archive -project HermedBots.xcodeproj -scheme HermedBots -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$work/HermedBots.xcarchive" \
  -derivedDataPath "$work/dd" -clonedSourcePackagesDirPath "$work/packages" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$version" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_IDENTITY='Developer ID Application' \
  CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp ENABLE_HARDENED_RUNTIME=YES \
  SPARKLE_FEED_URL="$feed" SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY"
cat > "$private/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$APPLE_TEAM_ID</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$work/HermedBots.xcarchive" \
  -exportPath "$work/export" -exportOptionsPlist "$private/ExportOptions.plist"
echo build >> "$stages"
app="$work/export/HermedBots.app"
codesign --verify --deep --strict --verbose=2 "$app"
echo signature >> "$stages"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarize.zip"
xcrun notarytool submit "$work/notarize.zip" --key "$private/AuthKey.p8" \
  --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --output-format json > "$work/notary.json"
node -e 'if (require(process.argv[1]).status !== "Accepted") process.exit(1)' "$work/notary.json"
echo notarization >> "$stages"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
echo stapling >> "$stages"
spctl -a -vv --type execute "$app" > "$work/spctl.txt" 2>&1
cat "$work/spctl.txt"
archive="$work/out/HermedBots-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
tools="$work/packages/artifacts/sparkle/Sparkle/bin"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - \
  --download-url-prefix "https://github.com/$DISTRIBUTION_REPOSITORY/releases/download/$tag/" \
  --link "https://github.com/$DISTRIBUTION_REPOSITORY" "$work/out"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --verify --ed-key-file - "$work/out/appcast.xml"
sha=$(shasum -a 256 "$archive" | cut -d' ' -f1)
node scripts/distribution.js cask "$tag" "$sha" "$DISTRIBUTION_REPOSITORY" > "$work/out/hermed-bots.rb"
(
  cd "$work/out"
  shasum -a 256 "HermedBots-$version.zip" appcast.xml hermed-bots.rb > SHA256SUMS
)
git rev-parse HEAD > "$work/out/commit.txt"
