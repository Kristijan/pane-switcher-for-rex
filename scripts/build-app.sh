#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -m)" != arm64 ]]; then
  printf 'Pane Switcher for Rex supports Apple Silicon (arm64) only.\n' >&2
  exit 1
fi
python3 "$ROOT/scripts/release-support.py" validate --plist "$ROOT/Resources/Info.plist" >&2
swift build -c release --arch arm64 >&2
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP="$ROOT/.build/Pane Switcher for Rex.app"
# Recreate only this generated bundle so stale resources cannot enter a release.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PaneSwitch" "$APP/Contents/MacOS/PaneSwitch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
python3 "$ROOT/scripts/release-support.py" validate --plist "$APP/Contents/Info.plist" \
  --architectures "$(lipo -archs "$APP/Contents/MacOS/PaneSwitch")" >&2
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
