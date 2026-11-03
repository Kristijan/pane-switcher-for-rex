#!/bin/bash
# Production only. Local source builds use build-app.sh and remain explicitly ad-hoc signed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 1 ]]; then
  printf 'Usage: %s vMAJOR.MINOR.PATCH\n' "$0" >&2
  exit 2
fi
TAG="$1"
VERSION="$(python3 "$ROOT/scripts/release-support.py" validate --plist "$ROOT/Resources/Info.plist" --tag "$TAG")"
OUTPUT="$ROOT/dist/$VERSION"
if [[ -e "$OUTPUT" ]]; then
  printf 'Release artifacts already exist at %s; inspect them before retrying.\n' "$OUTPUT" >&2
  exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
  printf 'Production releases require an Apple Silicon (arm64) host.\n' >&2
  exit 1
fi
for NAME in APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD DEVELOPER_ID_APPLICATION_IDENTITY APPLE_TEAM_ID NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_PRIVATE_KEY; do
  if [[ -z "${!NAME:-}" ]]; then
    printf 'Production signing requires %s; refusing an ad-hoc release.\n' "$NAME" >&2
    exit 1
  fi
done
IDENTITY="$DEVELOPER_ID_APPLICATION_IDENTITY"
if [[ "$IDENTITY" != 'Developer ID Application: '* || "$IDENTITY" != *" ($APPLE_TEAM_ID)" ]]; then
  printf 'Signing identity must be a Developer ID Application certificate belonging to APPLE_TEAM_ID.\n' >&2
  exit 1
fi
umask 077
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/PaneSwitch-release.XXXXXX")"
KEYCHAIN="$TEMP/release.keychain-db"
cleanup() {
  local result=$?
  trap - EXIT
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$TEMP"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$TEMP/certificate.p12"
printf '%s' "$NOTARY_PRIVATE_KEY" > "$TEMP/notary-key.p8"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$TEMP/certificate.p12" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN")"
if [[ "$IDENTITIES" != *"\"$IDENTITY\""* ]]; then
  printf 'No valid requested Developer ID signing identity with a private key was imported.\n' >&2
  exit 1
fi
APP="$("$ROOT/scripts/build-app.sh")"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --options runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
DETAILS="$(codesign --display --verbose=4 "$APP" 2>&1)"
if [[ "$DETAILS" != *"Authority=$IDENTITY"* || "$DETAILS" != *"TeamIdentifier=$APPLE_TEAM_ID"* || "$DETAILS" != *"(runtime)"* ]]; then
  printf 'Production bundle lacks the expected Developer ID authority, team, or hardened runtime.\n' >&2
  exit 1
fi
"$ROOT/scripts/smoke-app.sh" "$APP"
# Submit a temporary ZIP; only the final ZIP made AFTER stapling is distributed.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP/notarization.zip"
xcrun notarytool submit "$TEMP/notarization.zip" --key "$TEMP/notary-key.p8" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait \
  --output-format json > "$TEMP/notarization.json"
python3 -c 'import json,sys; result=json.load(open(sys.argv[1])); print("Notarization:", result.get("id"), result.get("status")); sys.exit(0 if result.get("status") == "Accepted" else 1)' "$TEMP/notarization.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
mkdir -p "$OUTPUT"
ARCHIVE="Pane-Switcher-for-Rex-$VERSION-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP/$ARCHIVE"
# Smoke the actual archived bundle, not just the pre-archive directory.
mkdir "$TEMP/extracted"
ditto -x -k "$TEMP/$ARCHIVE" "$TEMP/extracted"
"$ROOT/scripts/smoke-app.sh" "$TEMP/extracted/Pane Switcher for Rex.app"
xcrun stapler validate "$TEMP/extracted/Pane Switcher for Rex.app"
python3 "$ROOT/scripts/release-support.py" cask --version "$VERSION" \
  --zip "$TEMP/$ARCHIVE" --output "$TEMP/pane-switcher-for-rex.rb"
ruby -c "$TEMP/pane-switcher-for-rex.rb"
(cd "$TEMP" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
cp "$TEMP/$ARCHIVE" "$TEMP/$ARCHIVE.sha256" "$TEMP/pane-switcher-for-rex.rb" "$OUTPUT/"
printf 'Production artifacts: %s\n' "$OUTPUT"
