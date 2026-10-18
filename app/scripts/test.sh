#!/bin/bash
# Run the unit tests. Use this instead of a bare `swift test`.
# With Command Line Tools only (no Xcode), SwiftPM intermittently drops the
# `-plugin-path` for the swift-testing macros and the build fails with
# "plugin for module 'TestingMacros' not found" (decisions.md D-009).
# Passing the path explicitly makes it deterministic.
set -euo pipefail
cd "$(dirname "$0")/.."
toolchain_bin="$(dirname "$(xcrun --find swift)")"
plugins="$toolchain_bin/../lib/swift/host/plugins/testing"
extra=()
[ -d "$plugins" ] && extra=(-Xswiftc -plugin-path -Xswiftc "$plugins")
exec swift test "${extra[@]}" "$@"
