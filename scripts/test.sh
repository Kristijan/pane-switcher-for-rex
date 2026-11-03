#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Command Line Tools ship Swift Testing as a framework, outside swiftc's default search path.
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
TEST_ARGS=(--disable-xctest)
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  TEST_ARGS+=(-Xswiftc "-F$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS")
fi
# Swift Build does not discover CLT's nested Swift Testing macro plugin directory.
TOOLCHAIN_BIN="$(dirname "$(xcrun --find swiftc)")"
TESTING_PLUGINS="$TOOLCHAIN_BIN/../lib/swift/host/plugins/testing"
if [[ -f "$TESTING_PLUGINS/libTestingMacros.dylib" ]]; then
  TEST_ARGS+=(-Xswiftc -external-plugin-path -Xswiftc "$TESTING_PLUGINS#$TOOLCHAIN_BIN/swift-plugin-server")
fi
swift test "${TEST_ARGS[@]}" "$@"
