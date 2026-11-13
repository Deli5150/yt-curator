#!/bin/sh
# Publish a release: scripts/release.sh <version>
# Needs a clean tree and a "## <version>" section in CHANGELOG.md (used as the release notes).
# Bumps VERSION, commits, builds and zips the app, tags, pushes, and creates the GitHub release
# the in-app updater reads (asset: YT-Curator-<version>.dmg).
set -eu
cd "$(dirname "$0")/.."

V="${1:?usage: scripts/release.sh <version>}"
DMG="build/YT-Curator-$V.dmg"

[ -z "$(git status --porcelain)" ] || { echo "Working tree not clean"; exit 1; }
NOTES="$(awk -v v="## $V" '$0 == v {on=1; next} /^## / {on=0} on' CHANGELOG.md)"
[ -n "$NOTES" ] || { echo "No '## $V' section in CHANGELOG.md"; exit 1; }

echo "$V" > VERSION
git add VERSION
git diff --cached --quiet || git commit -qm "Release v$V"

./scripts/bundle.sh
# Drag-to-install DMG: the app next to an Applications shortcut.
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "build/YT Curator.app" "$STAGE/YT Curator.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "YT Curator" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

git tag "v$V"
git push -q origin HEAD "v$V"
gh release create "v$V" "$DMG" --title "YT Curator $V" --notes "$NOTES"
echo "Released v$V"
