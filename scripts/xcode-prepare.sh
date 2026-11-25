#!/usr/bin/env bash
# Generate DAVDrive.xcodeproj (macOS, needs XcodeGen: brew install xcodegen).
#
# Usage: scripts/xcode-prepare.sh [build-suffix]
#   build-suffix: appended to the build number (CI passes the run number), so
#   every App Store upload gets a new, increasing build number: 1 -> 1.57.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .xcode

# Info.plists: xtool's files plus the keys xtool adds itself, for Xcode.
# (Separate .py file: macOS's bash 3.2 mangles a heredoc inside "< <(...)".)
read -r DD_VERSION DD_BUILD < <(python3 -I scripts/xcode_info.py "${1:-}" \
  Config/App-Info.plist .xcode/App-Info.plist \
  Config/FileProvider-Info.plist .xcode/FileProvider-Info.plist)
export DD_VERSION DD_BUILD

# App icon asset catalog, from the same PNG xtool uses.
icon=.xcode/Assets.xcassets/AppIcon.appiconset
mkdir -p "$icon"
cp Resources/AppIcon.png "$icon/AppIcon.png"
echo '{ "info" : { "author" : "xcode", "version" : 1 } }' > .xcode/Assets.xcassets/Contents.json
cat > "$icon/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

xcodegen generate --quiet
echo "Generated DAVDrive.xcodeproj: version $DD_VERSION, build $DD_BUILD"
