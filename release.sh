#!/bin/zsh
# Builds a Developer ID-signed, notarized and stapled "Better Notepad.dmg" in ./build/.
# Needs a notarytool keychain profile named "notary":
#   xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id Z6U97H9M93
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROFILE="${NOTARY_PROFILE:-notary}"
IDENTITY="Developer ID Application: Cyber Support IT LLC (Z6U97H9M93)"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/BetterNotepad-Release"
APP_NAME="Better Notepad.app"
OUT="build"
BUILT="$DERIVED/Build/Products/Release/$APP_NAME"

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

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

echo "==> Building Release"
rm -rf "$DERIVED/Build/Products/Release"
xcodebuild -project BetterNotepad.xcodeproj -scheme BetterNotepad -configuration Release \
  -derivedDataPath "$DERIVED" build | grep -E "error:|BUILD" || true
[[ -d "$BUILT" ]] || { echo "Build failed"; exit 1; }
codesign --verify --deep --strict "$BUILT"
if codesign -d --entitlements - "$BUILT" 2>/dev/null | grep -q get-task-allow; then
  echo "Build still has get-task-allow; notarization would reject it"; exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
rm -rf "$OUT" && mkdir -p "$OUT/stage"

echo "==> Notarizing the app"
ditto "$BUILT" "$OUT/stage/$APP_NAME"
ditto -c -k --keepParent "$OUT/stage/$APP_NAME" "$OUT/app.zip"
notarize "$OUT/app.zip"
xcrun stapler staple "$OUT/stage/$APP_NAME"
rm "$OUT/app.zip"

echo "==> Building the disk image"
ln -s /Applications "$OUT/stage/Applications"
DMG="$OUT/Better-Notepad-$VERSION.dmg"
hdiutil create -volname "Better Notepad" -srcfolder "$OUT/stage" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"
rm -rf "$OUT/stage"

spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "Done: $DMG"
