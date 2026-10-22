#!/bin/bash
set -euo pipefail
set +x

cd "$(dirname "$0")/.."
tag=${1:?Expected vX.Y.Z}
version=$(node scripts/distribution.js version "$tag")
: "${DISTRIBUTION_REPOSITORY:?Expected approved public repository}"
: "${GH_TOKEN:?Expected distribution repository token}"
if [ "${DISTRIBUTION_APPROVED:-}" != true ]; then
  echo 'Public distribution requires DISTRIBUTION_APPROVED=true' >&2
  exit 1
fi
work="$PWD/.audit/distribution"
(cd "$work/out" && shasum -a 256 -c SHA256SUMS)
test "$(gh api "repos/$DISTRIBUTION_REPOSITORY" --jq .visibility)" = public
latest=''
if gh release view --repo "$DISTRIBUTION_REPOSITORY" --json tagName > "$work/latest.json" 2> "$work/release-error.txt"; then
  latest=$(node -p 'require(process.argv[1]).tagName' "$work/latest.json")
else
  grep -qi 'release not found' "$work/release-error.txt"
fi
node scripts/distribution.js order "$tag" "$latest"
published=false
if gh release view "$tag" --repo "$DISTRIBUTION_REPOSITORY" --json isDraft > "$work/release.json" 2> "$work/release-error.txt"; then
  published=$(node -p '!require(process.argv[1]).isDraft' "$work/release.json")
else
  grep -qi 'release not found' "$work/release-error.txt"
  source_sha=$(git rev-parse HEAD)
  gh release create "$tag" --repo "$DISTRIBUTION_REPOSITORY" --draft \
    --title "Hermed Bots $version" --notes "Source commit $source_sha. Archive and feed hashes are in SHA256SUMS."
fi
if [ "$published" = true ]; then
  # A retry may finish the tap, but cannot replace immutable release bytes
  mkdir -p "$work/published"
  gh release download "$tag" --repo "$DISTRIBUTION_REPOSITORY" --pattern SHA256SUMS --dir "$work/published" --clobber
  cmp "$work/out/SHA256SUMS" "$work/published/SHA256SUMS"
else
  gh release upload "$tag" --repo "$DISTRIBUTION_REPOSITORY" --clobber \
    "$work/out/HermedBots-$version.zip" "$work/out/appcast.xml" \
    "$work/out/hermed-bots.rb" "$work/out/SHA256SUMS" "$work/out/commit.txt"
  gh release edit "$tag" --repo "$DISTRIBUTION_REPOSITORY" --draft=false --latest
fi
tap=$(node scripts/distribution.js tap "$DISTRIBUTION_REPOSITORY")
path="repos/$tap/contents/Casks/hermed-bots.rb"
# Only a 404 means absence; permission and transport failures stop publication
if gh api "$path" > "$work/cask.json" 2> "$work/cask-error.txt"; then
  sha=$(node -p 'require(process.argv[1]).sha' "$work/cask.json")
  if node - "$work/cask.json" "$work/out/hermed-bots.rb" <<'JS'
const fs = require('node:fs');
const [, , remote, local] = process.argv;
const content = Buffer.from(JSON.parse(fs.readFileSync(remote)).content, 'base64');
process.exit(content.equals(fs.readFileSync(local)) ? 0 : 1);
JS
  then
    echo 'Homebrew cask already current'
    exit 0
  fi
else
  grep -q 'HTTP 404' "$work/cask-error.txt"
  sha=''
fi
base64 < "$work/out/hermed-bots.rb" | tr -d '\n' > "$work/cask-base64.txt"
node - "$work/cask-base64.txt" "$sha" "$version" > "$work/cask-request.json" <<'JS'
const fs = require('node:fs');
const [, , file, sha, version] = process.argv;
const body = { message: `chore(cask): release Hermed Bots ${version}`, content: fs.readFileSync(file, 'utf8') };
if (sha) body.sha = sha;
console.log(JSON.stringify(body));
JS
gh api --method PUT "$path" --input "$work/cask-request.json" --silent
