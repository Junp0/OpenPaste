#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/build/OpenPaste.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/OpenPaste" "$app_dir/Contents/MacOS/OpenPaste"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [ ! -f build/OpenPaste.icns ] || [ ! -f build/OpenPasteStatus.pdf ] || [ scripts/make-icon.swift -nt build/OpenPaste.icns ]; then
    swift scripts/make-icon.swift
fi
cp build/OpenPaste.icns "$app_dir/Contents/Resources/OpenPaste.icns"
cp build/OpenPasteStatus.pdf "$app_dir/Contents/Resources/OpenPasteStatus.pdf"
./scripts/sign-app.sh "$app_dir"
echo "已构建：$app_dir"
