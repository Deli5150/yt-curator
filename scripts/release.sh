#!/bin/sh
# Publish a release: scripts/release.sh <version>
# Needs a clean tree and a "## <version>" section in CHANGELOG.md (used as the release notes).
# Bumps VERSION, commits, builds and zips the app, tags, pushes, and creates the GitHub release
# the in-app updater reads (asset: YT-Curator-<version>-mac.zip).
set -eu
cd "$(dirname "$0")/.."

V="${1:?usage: scripts/release.sh <version>}"
ZIP="build/YT-Curator-$V-mac.zip"

[ -z "$(git status --porcelain)" ] || { echo "Working tree not clean"; exit 1; }
NOTES="$(awk -v v="## $V" '$0 == v {on=1; next} /^## / {on=0} on' CHANGELOG.md)"
[ -n "$NOTES" ] || { echo "No '## $V' section in CHANGELOG.md"; exit 1; }

echo "$V" > VERSION
git add VERSION
git diff --cached --quiet || git commit -qm "Release v$V"

./scripts/bundle.sh
rm -f "$ZIP"
ditto -c -k --keepParent "build/YT Curator.app" "$ZIP"

git tag "v$V"
git push -q origin HEAD "v$V"
gh release create "v$V" "$ZIP" --title "YT Curator $V" --notes "$NOTES"
echo "Released v$V"
