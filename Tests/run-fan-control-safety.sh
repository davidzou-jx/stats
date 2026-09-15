#!/bin/sh
set -eu

# Run from the repository root after a Debug build. No app or controller is launched.
fan_build_dir="${1:-/private/tmp/stats-fan-safety-build}"
fan_test_dir="$(mktemp -d /private/tmp/stats-fan-tests.XXXXXX)"
xcrun swiftc \
    -module-cache-path "$fan_build_dir/ModuleCache.noindex" \
    -parse-as-library -I Kit/lldb \
    -F "$fan_build_dir/Build/Products/Debug" -framework Sensors -framework Kit \
    -Xlinker -rpath -Xlinker "$fan_build_dir/Build/Products/Debug" \
    Tests/FanControlSafety.swift -o "$fan_test_dir/fan-control-safety"
"$fan_test_dir/fan-control-safety"
