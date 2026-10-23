#!/usr/bin/env bash
# Runs `swift test` with the flags the Command Line Tools need to find Testing.framework.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)/Library/Developer"

exec swift test \
    -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
    -Xlinker -F -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
    "$@"
