#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -d build/OpenPaste.app ]; then
    ./scripts/build.sh
fi
open build/OpenPaste.app
