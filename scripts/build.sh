#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/build/iPaste.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/iPaste" "$app_dir/Contents/MacOS/iPaste"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [ ! -f build/iPaste.icns ] || [ ! -f build/iPasteStatus.pdf ] || [ scripts/make-icon.swift -nt build/iPaste.icns ]; then
    swift scripts/make-icon.swift
fi
cp build/iPaste.icns "$app_dir/Contents/Resources/iPaste.icns"
cp build/iPasteStatus.pdf "$app_dir/Contents/Resources/iPasteStatus.pdf"
./scripts/sign-app.sh "$app_dir"
echo "已构建：$app_dir"
