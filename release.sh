#!/bin/zsh
# Builds a Developer ID-signed, notarized and stapled build/Better-Notepad.dmg plus the
# Sparkle update feed build/appcast.xml. Publish both as assets of a GitHub release:
#   gh release create v<version> build/Better-Notepad.dmg build/appcast.xml --title "Better Notepad <version>"
# The website link .../releases/latest/download/Better-Notepad.dmg then always gets the newest
# version, and installed copies find the update through .../releases/latest/download/appcast.xml.
#
# Needs:
#   - a notarytool keychain profile named "notary":
#       xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id Z6U97H9M93
#   - the Sparkle update signing key (private half of SUPublicEDKey in Info.plist) at
#       ~/.config/better-notepad/sparkle_private_key   (override with SPARKLE_KEY_FILE)
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROFILE="${NOTARY_PROFILE:-notary}"
IDENTITY="Developer ID Application: Cyber Support IT LLC (Z6U97H9M93)"
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-$HOME/.config/better-notepad/sparkle_private_key}"
REPO="saoneill01-a11y/Better-Notepad"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/BetterNotepad-Release"
APP_NAME="Better Notepad.app"
OUT="build"
# Work outside the project folder: cloud-synced folders (OneDrive) add extended attributes
# that code signing rejects. Only the finished files are copied into ./build.
WORK="$DERIVED/release-work"
BUILT="$DERIVED/Build/Products/Release/$APP_NAME"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

[[ -f "$SPARKLE_KEY_FILE" ]] || { echo "Missing Sparkle key: $SPARKLE_KEY_FILE"; exit 1; }

# Submits a file and fails (printing Apple's log) unless it comes back Accepted.
notarize() {
  local out id
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
  echo "$out" | grep -E "^ *(id|status):" | sort -u
  if ! echo "$out" | grep -q "status: Accepted"; then
    id=$(echo "$out" | awk '/^ *id:/{print $2; exit}')
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE"
    echo "Notarization failed for $1"; exit 1
  fi
}

sign() {
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"
}

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

echo "==> Building Release"
rm -rf "$DERIVED/Build/Products/Release"
xcodebuild -project BetterNotepad.xcodeproj -scheme BetterNotepad -configuration Release \
  -derivedDataPath "$DERIVED" build | grep -E "error:|BUILD" || true
[[ -d "$BUILT" ]] || { echo "Build failed"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$BUILT/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$BUILT/Contents/Info.plist")
rm -rf "$WORK" && mkdir -p "$WORK/stage"
STAGED="$WORK/stage/$APP_NAME"
ditto --norsrc --noextattr "$BUILT" "$STAGED"
xattr -cr "$STAGED"

echo "==> Signing Sparkle and the app"
# Sparkle's helpers ship without our signature; notarization needs every piece signed by us
# with the hardened runtime. Inside out, then the app itself.
FW="$STAGED/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$STAGED"
codesign --verify --deep --strict "$STAGED"
if codesign -d --entitlements - "$STAGED" 2>/dev/null | grep -q get-task-allow; then
  echo "Build still has get-task-allow; notarization would reject it"; exit 1
fi

echo "==> Notarizing the app"
ditto -c -k --keepParent "$STAGED" "$WORK/app.zip"
notarize "$WORK/app.zip"
xcrun stapler staple "$STAGED"
rm "$WORK/app.zip"

echo "==> Building the disk image"
ln -s /Applications "$WORK/stage/Applications"
DMG="$WORK/Better-Notepad.dmg"
hdiutil create -volname "Better Notepad" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "==> Writing the update feed"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG")
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
cat > "$WORK/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Better Notepad</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Better-Notepad.dmg"
                 $SIGNATURE
                 type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
rm -rf "$OUT" && mkdir -p "$OUT"
cp "$DMG" "$WORK/appcast.xml" "$OUT/"
# Keep a copy of the notarized app for installing locally.
rm -rf "$WORK/app" && mkdir -p "$WORK/app" && ditto "$STAGED" "$WORK/app/$APP_NAME"
echo "Done: $OUT/Better-Notepad.dmg and $OUT/appcast.xml (version $VERSION, build $BUILD_NUMBER)"
