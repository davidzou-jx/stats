#!/bin/sh
set -eu

# Build Debug first. Run existing unit tests and runtime regressions without
# launching Stats, opening its database, or contacting the SMC helper.
build_dir="${1:-/private/tmp/stats-efficiency-build}"
test_dir="$(mktemp -d /private/tmp/stats-runtime-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
import re
import sys
from pathlib import Path
sources = ['Tests/Kit.swift', 'Tests/RAM.swift', 'Tests/FanCurve.swift', 'Tests/RuntimeSafety.swift']
entries = []
for source in sources:
    text = Path(source).read_text()
    name = re.search(r'class (\w+): XCTestCase', text).group(1)
    entries.append(f'suite.addTest(XCTestSuite(forTestCaseClass: {name}.self))')
Path(sys.argv[1]).write_text('import XCTest\nimport Darwin\nlet suite = XCTestSuite(name: "Stats regressions")\n' + '\n'.join(entries) + '\nsuite.run()\nguard let result = suite.testRun, result.executionCount > 0 else { exit(2) }\nexit(result.hasSucceeded ? 0 : 1)\n')
PY
xctest_dir="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
xctest_lib="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -Xlinker -rpath -Xlinker "$xctest_dir/../PrivateFrameworks" -I "$xctest_lib" -L "$xctest_lib" -Xlinker -rpath -Xlinker "$xctest_lib" -F "$xctest_dir" -Xlinker -rpath -Xlinker "$xctest_dir" -module-cache-path "$build_dir/ModuleCache.noindex" -I Kit/lldb \
    -F "$build_dir/Build/Products/Debug" -framework Kit -framework RAM -framework Net -framework Disk \
    -Xlinker -rpath -Xlinker "$build_dir/Build/Products/Debug" \
    Tests/Kit.swift Tests/RAM.swift Tests/FanCurve.swift Tests/RuntimeSafety.swift \
    "$test_dir/main.swift" -o "$test_dir/runtime-safety"
"$test_dir/runtime-safety"
