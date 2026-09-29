#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
sources=(Sources/*.swift)
sources=(${sources:#Sources/Main.swift})
xcrun swiftc -swift-version 5 -parse-as-library "${sources[@]}" scripts/TabInteractionChecks.swift -o build/TabInteractionChecks
./build/TabInteractionChecks
