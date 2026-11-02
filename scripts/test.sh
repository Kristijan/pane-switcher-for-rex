#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Command Line Tools ship Swift Testing as a framework, outside swiftc's default search path.
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  swift test --build-system native --disable-xctest \
    -Xswiftc "-F$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
else
  swift test --build-system native --disable-xctest "$@"
fi
