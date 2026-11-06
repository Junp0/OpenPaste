#!/bin/bash
# Package an already-built, signed app. Final deliverables all go in release/.
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="${1:-$PWD/build/OpenPaste.app}"
if [ ! -d "$source_app/Contents" ]; then
    echo "找不到应用包：$source_app；请先运行 ./scripts/build.sh，或传入应用包路径。" >&2
    exit 1
fi
source_app="$(cd "$source_app" && pwd -P)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "无效的应用版本号：$version" >&2
    exit 1
fi
codesign --verify --deep --strict "$source_app"
mkdir -p build release
tools_python="$PWD/build/dmg-tools/bin/python"
if [ ! -x "$tools_python" ]; then
    python3 -m venv "$PWD/build/dmg-tools"
fi
if ! "$tools_python" -c 'from importlib.metadata import version; assert version("ds-store") == "1.3.1"; assert version("mac-alias") == "2.2.2"' 2>/dev/null; then
    "$tools_python" -m pip --disable-pip-version-check install -r scripts/requirements-dmg.txt
fi
package_stage="$(mktemp -d "$PWD/build/package-release.XXXXXX")"
mount_point="$package_stage/mount"
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then
        if ! hdiutil detach "$mount_point"; then
            echo "临时安装镜像仍被占用，保留：$package_stage" >&2
            return
        fi
    fi
    rm -rf "$package_stage"
}
trap cleanup EXIT
mkdir -p "$package_stage/payload/.background" "$mount_point"
ditto "$source_app" "$package_stage/payload/OpenPaste.app"
codesign --verify --deep --strict "$package_stage/payload/OpenPaste.app"
ln -s /Applications "$package_stage/payload/应用程序"
swift scripts/make-dmg-background.swift "$package_stage/artwork" "$version"
cp "$package_stage/artwork/background.tiff" "$package_stage/payload/.background/"
cp "$source_app/Contents/Resources/OpenPaste.icns" "$package_stage/payload/.VolumeIcon.icns"
touch "$package_stage/payload/.metadata_never_index"
dmg_path="$PWD/release/OpenPaste-$version.dmg"
hdiutil create -volname "OpenPaste $version" -fs HFS+ -layout NONE -format UDRW \
    -srcfolder "$package_stage/payload" "$package_stage/writable.dmg"
hdiutil attach -nobrowse -noautoopen -owners off -mountpoint "$mount_point" "$package_stage/writable.dmg"
mounted=true
"$tools_python" scripts/configure-dmg.py write "$mount_point"
SetFile -a C "$mount_point"
SetFile -a V "$mount_point/.background" "$mount_point/.VolumeIcon.icns"
"$tools_python" scripts/configure-dmg.py verify "$mount_point"
codesign --verify --deep --strict "$mount_point/OpenPaste.app"
hdiutil detach "$mount_point"
mounted=false
hdiutil convert "$package_stage/writable.dmg" -format UDZO -imagekey zlib-level=9 \
    -o "$package_stage/final.dmg"
hdiutil verify "$package_stage/final.dmg"
hdiutil attach -readonly -nobrowse -noautoopen -owners off -mountpoint "$mount_point" "$package_stage/final.dmg"
mounted=true
"$tools_python" scripts/configure-dmg.py verify "$mount_point"
codesign --verify --deep --strict "$mount_point/OpenPaste.app"
diff -qr "$source_app" "$mount_point/OpenPaste.app"
hdiutil detach "$mount_point"
mounted=false
# Publish only after the compressed image has passed the mounted-content checks.
mv "$package_stage/final.dmg" "$dmg_path"
cp "$package_stage/artwork/background@2x.png" "$PWD/build/dmg-background@2x.png"
ditto "$package_stage/payload/OpenPaste.app" "$PWD/release/OpenPaste.app"
codesign --verify --deep --strict "$PWD/release/OpenPaste.app"
ditto -c -k --sequesterRsrc --keepParent "$package_stage/payload/OpenPaste.app" "$PWD/release/OpenPaste-$version.zip"
(cd release && shasum -a 256 "OpenPaste-$version.dmg" "OpenPaste-$version.zip") > "$PWD/release/SHA256SUMS.txt"
echo "已打包：$dmg_path"
