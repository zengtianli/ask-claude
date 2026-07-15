#!/bin/bash
# build.sh — build Ask Claude.app (Release) and optionally install it.
#
#   ./build.sh             build → ./build/Ask Claude.app
#   ./build.sh --install   build + copy into /Applications (falls back to ~/Applications)
#
# The app is ad-hoc signed (no Apple Developer certificate required). If you
# downloaded a prebuilt zip instead of building locally, clear the quarantine
# flag once:  xattr -cr "/Applications/Ask Claude.app"
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

APP_NAME="Ask Claude"

# xcodebuild needs a full Xcode (not just Command Line Tools).
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "→ Building (Release)…"
xcodebuild -project AskClaude.xcodeproj -scheme AskClaude -configuration Release build | tail -3

BUILT="$(xcodebuild -project AskClaude.xcodeproj -scheme AskClaude -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')"
SRC_APP="$BUILT/AskClaude.app"
[ -d "$SRC_APP" ] || { echo "❌ Build product not found: $SRC_APP"; exit 1; }

echo "→ Post-build (display name / icon / build number / ad-hoc re-sign)…"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$SRC_APP/Contents/Info.plist"
plutil -replace CFBundleIconFile -string "AppIcon" "$SRC_APP/Contents/Info.plist"
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  plutil -replace CFBundleVersion -string "$(git -C "$DIR" rev-list --count HEAD)" "$SRC_APP/Contents/Info.plist"
fi
cp "$DIR/icon/AppIcon.icns" "$SRC_APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$SRC_APP"   # resources changed → re-sign (ad-hoc)

mkdir -p "$DIR/build"
rm -rf "$DIR/build/$APP_NAME.app"
cp -R "$SRC_APP" "$DIR/build/$APP_NAME.app"
echo "✅ Built → $DIR/build/$APP_NAME.app"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/$APP_NAME.app"
  if ! rm -rf "$DEST" 2>/dev/null || ! cp -R "$DIR/build/$APP_NAME.app" "$DEST" 2>/dev/null; then
    DEST="$HOME/Applications/$APP_NAME.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"; cp -R "$DIR/build/$APP_NAME.app" "$DEST"
  fi
  echo "✅ Installed → $DEST"
fi
