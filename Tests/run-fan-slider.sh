#!/bin/sh
set -eu

# Run after a Debug build. The UI runner never launches Stats or FanController.
slider_build_dir="${1:-/private/tmp/stats-slider-build}"
slider_test_dir="$(mktemp -d /private/tmp/stats-slider-tests.XXXXXX)"
trap 'rm -rf "$slider_test_dir"' EXIT
xcrun swiftc \
    -module-cache-path "$slider_build_dir/ModuleCache.noindex" \
    -parse-as-library -I Kit/lldb \
    -F "$slider_build_dir/Build/Products/Debug" -framework Sensors -framework Kit \
    -Xlinker -rpath -Xlinker "$slider_build_dir/Build/Products/Debug" \
    Tests/FanSlider.swift -o "$slider_test_dir/fan-slider"
if [ "$#" -gt 1 ]; then
    "$slider_test_dir/fan-slider" "$2"
else
    "$slider_test_dir/fan-slider"
fi
