#!/usr/bin/env bash
# Packages an unsigned .ipa from an .xcarchive, for re-signing on the phone side
# (AltStore / SideStore) or with a 99 USD developer certificate.
#
# Usage: scripts/package-ipa.sh <path/to/App.xcarchive> [output-dir]
#
# Produces <output-dir>/DAVDrive-unsigned-<version>-<build>.ipa and checks that
# the File Provider extension actually made it into the bundle: an .ipa that
# installs but has no PlugIns/DAVDriveFileProvider.appex cannot show up in Files,
# which is a confusing way to waste a signing cycle.
set -euo pipefail

archive="${1:?usage: package-ipa.sh <path/to/App.xcarchive> [output-dir]}"
out="${2:-build/ipa}"
app="$archive/Products/Applications/DAVDrive.app"

[ -d "$archive" ] || { echo "no such archive: $archive" >&2; exit 1; }
[ -d "$app" ]     || { echo "no app in archive: $app" >&2; exit 1; }

# The extension is the whole point of this app.
appex="$app/PlugIns/DAVDriveFileProvider.appex"
if [ ! -d "$appex" ]; then
  echo "ERROR: the File Provider extension is missing from the app bundle." >&2
  echo "       An .ipa without it installs fine and then shows nothing in Files." >&2
  ls -1 "$app/PlugIns" 2>/dev/null || echo "       (no PlugIns directory at all)" >&2
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")
name="DAVDrive-unsigned-${version}-${build}.ipa"

mkdir -p "$out/Payload"
rm -rf "$out/Payload/DAVDrive.app"
cp -R "$app" "$out/Payload/DAVDrive.app"
rm -f "$out/$name"

# zip keeps symlinks and permissions; ditto is the macOS-native equivalent.
(cd "$out" && zip -qry "$name" Payload)
rm -rf "$out/Payload"

echo "IPA:  $out/$name"
echo "size: $(du -h "$out/$name" | cut -f1)"
echo "sha256: $(shasum -a 256 "$out/$name" | cut -d' ' -f1)"
echo
echo "Bundle:      $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
echo "Extension:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appex/Info.plist")"
echo "App group:   $(/usr/libexec/PlistBuddy -c 'Print :ALTAppGroups:0' "$app/Info.plist" 2>/dev/null || echo '(not declared)')"
echo
echo "Next: install with AltStore / SideStore and check that the location appears"
echo "in Files. If it does not, the app group was stripped at signing time;"
echo "see doc/BUILD_CUSTOMIZATION.md."
