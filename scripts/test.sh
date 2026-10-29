#!/usr/bin/env bash
# Runs `swift test`, adding the flags the Command Line Tools need to find Testing.framework.
# With full Xcode, `swift test` finds it on its own and no flags are added.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)/Library/Developer"
FLAGS=()
if [ -d "$DEV/Frameworks/Testing.framework" ]; then
    FLAGS=(
        -Xswiftc -F -Xswiftc "$DEV/Frameworks"
        -Xlinker -F -Xlinker "$DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$DEV/usr/lib"
    )
fi

exec swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
