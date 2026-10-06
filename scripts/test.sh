#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    Sources/Core.m Tests/CoreTests.m -framework Foundation -o .build/core-tests
.build/core-tests
python3 -m unittest discover -s Tests -v
python3 -m py_compile scripts/install.py
bash -n scripts/build.sh
