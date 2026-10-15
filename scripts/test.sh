#!/bin/sh
# Swift Testing is bundled separately when only the macOS Command Line Tools are installed.
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
if [ -d "$DEVELOPER_DIR_PATH/Library/Developer/Frameworks/Testing.framework" ]; then
    TEST_FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
    swift test --disable-sandbox --disable-xctest \
        -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
        -Xlinker -F -Xlinker "$TEST_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/usr/lib" "$@"
else
    swift test --disable-xctest "$@"
fi
