#!/bin/sh
# Build a release YT Curator.app into build/. Pass --install to copy it to /Applications.
set -eu
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VERSION="${VERSION:-1.0.0}"
APP="build/YT Curator.app"

swift build -c release --product YTCurator
BIN="$(swift build -c release --show-bin-path)/YTCurator"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/YTCurator"
cp Resources/AppIcon.icns Resources/curator-logo.png Resources/curator-logo-mark.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>YT Curator</string>
  <key>CFBundleDisplayName</key><string>YT Curator</string>
  <key>CFBundleIdentifier</key><string>com.delvison.ytcurator</string>
  <key>CFBundleExecutable</key><string>YTCurator</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/YT Curator.app"
  cp -R "$APP" "/Applications/YT Curator.app"
  echo "Installed /Applications/YT Curator.app"
fi
