#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGIN=false
case "${1:-}" in
  --login) LOGIN=true ;;
  '') ;;
  *) printf 'Usage: %s [--login]\n' "$0" >&2; exit 2 ;;
esac
if pgrep -x PaneSwitch >/dev/null; then
  printf 'Quit Pane Switcher for Rex from its menu-bar menu before installing.\n' >&2
  exit 1
fi
APP="$HOME/Applications/Pane Switcher for Rex.app"
LEGACY_APP="$HOME/Applications/Pane Switch.app"
BUNDLE_ID=com.kristijan.paneswitch
is_owned_app() {
  [[ -d "$1" && ! -L "$1" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]]
}
if [[ -e "$APP" || -L "$APP" ]] && ! is_owned_app "$APP"; then
  printf 'Refusing to replace an unrelated bundle or symbolic link: %s\n' "$APP" >&2
  exit 1
fi
"$ROOT/scripts/build-app.sh"
mkdir -p "$HOME/Applications"
STAGING="$(mktemp -d "$HOME/Applications/.PaneSwitch-install.XXXXXX")"
INSTALLED=false
COMMITTED=false
cleanup() {
  local result=$?
  trap - EXIT
  if ! "$COMMITTED"; then
    if "$INSTALLED"; then
      if ! is_owned_app "$APP"; then
        printf 'Destination changed during installation; leaving it and rollback files at %s untouched.\n' "$STAGING" >&2
        exit 1
      fi
      rm -rf "$APP"
    fi
    if [[ -d "$STAGING/previous.app" ]]; then
      if [[ -e "$APP" || -L "$APP" ]]; then
        printf 'Cannot restore over a changed destination; previous app remains at %s\n' "$STAGING/previous.app" >&2
        exit 1
      fi
      if ! mv "$STAGING/previous.app" "$APP"; then
        printf 'Could not restore the previous app; it remains at %s\n' "$STAGING/previous.app" >&2
        exit 1
      fi
    fi
  fi
  rm -rf "$STAGING"
  exit "$result"
}
trap cleanup EXIT
ditto "$ROOT/.build/Pane Switcher for Rex.app" "$STAGING/new.app"
is_owned_app "$STAGING/new.app"
[[ -x "$STAGING/new.app/Contents/MacOS/PaneSwitch" ]]
codesign --verify --deep --strict "$STAGING/new.app"
if [[ -e "$APP" || -L "$APP" ]]; then
  is_owned_app "$APP"
  mv "$APP" "$STAGING/previous.app"
fi
mv "$STAGING/new.app" "$APP"
INSTALLED=true
# These one-shot operations never start AppKit, workers, or load/unload a job.
# A failed login-agent migration leaves the old bundle intact and restores APP.
if "$LOGIN"; then
  "$APP/Contents/MacOS/PaneSwitch" --enable-login-agent
else
  "$APP/Contents/MacOS/PaneSwitch" --migrate-login-agent
fi
COMMITTED=true
# Only the known old location with the expected bundle ID is eligible for removal.
if is_owned_app "$LEGACY_APP"; then
  rm -rf "$LEGACY_APP"
fi
open -g "$APP"
printf 'Installed %s\nPress Control–Command–P while Rex is active.\n' "$APP"
