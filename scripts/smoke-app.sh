#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.build/Pane Switcher for Rex.app}"
if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [app-path]\n' "$0" >&2
  exit 2
fi
[[ -d "$APP" && -x "$APP/Contents/MacOS/PaneSwitch" && -s "$APP/Contents/Resources/AppIcon.icns" ]] || {
  printf 'Missing packaged app, executable, or icon: %s\n' "$APP" >&2
  exit 1
}
plutil -lint "$APP/Contents/Info.plist"
python3 "$ROOT/scripts/release-support.py" validate --plist "$APP/Contents/Info.plist" \
  --architectures "$(lipo -archs "$APP/Contents/MacOS/PaneSwitch")"
codesign --verify --deep --strict --verbose=2 "$APP"
# --help returns before AppKit, Rex connections, login-agent changes, or preferences.
HELP="$("$APP/Contents/MacOS/PaneSwitch" --help)"
[[ "$HELP" == *"Pane Switcher for Rex"* && "$HELP" == *"--show"* ]] || {
  printf 'Packaged executable did not return its command-line help.\n' >&2
  exit 1
}
printf 'Packaged arm64 app smoke check passed.\n'
