#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUT="${ROOT:h:h}/outputs"
APP="$OUT/Meet 放大鏡.app"
STAGE="$(mktemp -d)/Meet 放大鏡.app"
trap 'rm -rf "${STAGE:h}"' EXIT

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
xcrun swiftc "$ROOT/main.swift" \
  -o "$STAGE/Contents/MacOS/MeetMagnifier" \
  -framework AppKit -framework Carbon -framework ScreenCaptureKit \
  -parse-as-library
cp "$ROOT/Info.plist" "$STAGE/Contents/Info.plist"
cp "$ROOT/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
xattr -cr "$STAGE"
codesign --force --sign D46B6C4212DA2520A94167F445EA10801CBDE92B \
  --identifier local.codex.MeetMagnifier "$STAGE"
rm -rf "$APP"
ditto "$STAGE" "$APP"
xattr -cr "$APP"
echo "$APP"
