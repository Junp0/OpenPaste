#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -d build/iPaste.app ]; then
    ./scripts/build.sh
fi
open build/iPaste.app
