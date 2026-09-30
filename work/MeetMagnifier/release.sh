#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
PROJECT="${ROOT:h:h}"
OUTPUT="$PROJECT/outputs/Meet-Magnifier-1.1.0-macOS.zip"
STAGE_ROOT="$(mktemp -d)"
PUBLIC_APP="$STAGE_ROOT/Meet 放大鏡.app"
trap 'rm -rf "$STAGE_ROOT"' EXIT

"$ROOT/build.sh" >/dev/null
ditto "$PROJECT/outputs/Meet 放大鏡.app" "$PUBLIC_APP"
codesign --remove-signature "$PUBLIC_APP" 2>/dev/null || true
xattr -cr "$PUBLIC_APP"
codesign --force --deep --sign - --identifier local.codex.MeetMagnifier \
  -r '=designated => identifier "local.codex.MeetMagnifier"' "$PUBLIC_APP"
codesign --verify --deep "$PUBLIC_APP"
ditto -c -k --sequesterRsrc --keepParent "$PUBLIC_APP" "$OUTPUT"
shasum -a 256 "$OUTPUT"
