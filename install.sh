#!/bin/zsh
# Builds Better Notepad (Release) and installs it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/BetterNotepad-Release"
APP_NAME="Better Notepad.app"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

xcodebuild -project BetterNotepad.xcodeproj -scheme BetterNotepad -configuration Release \
  -derivedDataPath "$DERIVED" build | grep -E "error:|BUILD" || true

BUILT="$DERIVED/Build/Products/Release/$APP_NAME"
[[ -d "$BUILT" ]] || { echo "Build failed"; exit 1; }

osascript -e 'tell application id "com.betternotepad.BetterNotepad" to quit' 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP_NAME"
ditto "$BUILT" "/Applications/$APP_NAME"

# Make Launch Services pick up the .txt document type registration, and forget the
# build-folder copy so "Open With" / default-app choices always point at /Applications.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$BUILT" 2>/dev/null || true
"$LSREGISTER" -f "/Applications/$APP_NAME"

echo "Installed /Applications/$APP_NAME"
