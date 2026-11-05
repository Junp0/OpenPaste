#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc_binary="$(xcrun --find swiftc)"
testing_plugin="$(dirname "$swiftc_binary")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$testing_plugin" ]; then
    # Some CLT/SwiftBuild versions omit this plugin when switching configurations.
    swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin"
else
    swift test --disable-xctest
fi
