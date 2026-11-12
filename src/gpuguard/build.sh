#!/bin/bash
# Builds gpuguard.dylib and the standalone harness (Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")"
clang++ -std=c++17 -O2 -fobjc-arc -dynamiclib -arch arm64 -arch arm64e -Wall -Wno-unused-function -framework Metal -framework Foundation -framework AppKit -framework IOKit -o gpuguard.dylib gpuguard.mm
clang++ -std=c++17 -O2 -fobjc-arc -arch arm64 -Wall -framework Metal -framework Foundation -o gg_harness gg_harness.mm
echo built
