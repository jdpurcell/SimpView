#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/simpview-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$test_dir/modules" \
    SimpView/AppPreferences.swift SimpView/ImageDocument.swift \
    SimpView/ImageSource.swift SimpView/ImageNavigator.swift \
    SimpView/ImagePreloadCache.swift SimpView/CameraReadQueue.swift SimpView/CameraImageCache.swift \
    Tests/CameraNavigationTests.swift -o "$test_dir/tests"
"$test_dir/tests"
