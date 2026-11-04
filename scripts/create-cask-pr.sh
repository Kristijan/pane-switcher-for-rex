#!/bin/bash
# Called only after the production artifacts have been generated and uploaded to a draft release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 2 ]]; then
  printf 'Usage: %s vMAJOR.MINOR.PATCH artifact-directory\n' "$0" >&2
  exit 2
fi
TAG="$1"
ARTIFACTS="$2"
VERSION="$(python3 "$ROOT/scripts/release-support.py" validate --plist "$ROOT/Resources/Info.plist" --tag "$TAG")"
: "${GH_TOKEN:?GH_TOKEN is required to create the cask update pull request}"
APP_REPOSITORY="Kristijan/pane-switcher-for-rex"
TAP_REPOSITORY="Kristijan/homebrew-pane-switcher-for-rex"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/PaneSwitch-cask.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ARCHIVE="Pane-Switcher-for-Rex-$VERSION-arm64.zip"
(cd "$ARTIFACTS" && shasum -a 256 -c "$ARCHIVE.sha256")
python3 "$ROOT/scripts/release-support.py" cask --version "$VERSION" \
  --zip "$ARTIFACTS/$ARCHIVE" --output "$TEMP/pane-switcher-for-rex.rb" >/dev/null
cmp "$TEMP/pane-switcher-for-rex.rb" "$ARTIFACTS/pane-switcher-for-rex.rb"
BASE="$(gh api "repos/$TAP_REPOSITORY" --jq .default_branch)"
BASE_SHA="$(gh api "repos/$TAP_REPOSITORY/git/ref/heads/$BASE" --jq .object.sha)"
EXISTING_SHA="$(gh api "repos/$TAP_REPOSITORY/git/trees/$BASE_SHA?recursive=1" \
  --jq '.tree[] | select(.path == "Casks/pane-switcher-for-rex.rb") | .sha')"
CONTENT="$(base64 < "$ARTIFACTS/pane-switcher-for-rex.rb" | tr -d '\n')"
BRANCH="cask/$TAG"
ARGS=(--method PUT "repos/$TAP_REPOSITORY/contents/Casks/pane-switcher-for-rex.rb"
  -f "message=Update Homebrew cask to $VERSION" -f "branch=$BRANCH" -f "content=$CONTENT")
if [[ -n "$EXISTING_SHA" ]]; then
  ARGS+=(-f "sha=$EXISTING_SHA")
fi
# Deliberately fail if this branch exists: never overwrite an already reviewed cask PR.
gh api --method POST "repos/$TAP_REPOSITORY/git/refs" -f "ref=refs/heads/$BRANCH" -f "sha=$BASE_SHA" >/dev/null
gh api "${ARGS[@]}" >/dev/null
cat > "$TEMP/body.txt" <<EOF
Updates the dedicated Homebrew tap to $VERSION using the SHA-256 of the signed, notarized, stapled release ZIP.

- Review the draft release assets and signing/notarization results.
- Publish https://github.com/$APP_REPOSITORY/releases/tag/$TAG before merging this PR: draft assets are not publicly downloadable. Ready for review does not mean ready to merge.
- Review the cask's version, download URL, and checksum, and require any checks configured in this tap repository to pass.
EOF
gh pr create --repo "$TAP_REPOSITORY" --base "$BASE" --head "$BRANCH" \
  --title "Update Homebrew cask to $VERSION" --body-file "$TEMP/body.txt"
