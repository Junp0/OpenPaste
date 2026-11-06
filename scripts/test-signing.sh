#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="${1:-build/OpenPaste.app}"
qa_dir="$(mktemp -d "${TMPDIR:-/tmp}/ipaste-signing.XXXXXX")"
trap 'rm -rf "$qa_dir"' EXIT

ditto "$app_dir" "$qa_dir/before.app"
./scripts/sign-app.sh "$qa_dir/before.app"
ditto "$qa_dir/before.app" "$qa_dir/after.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion signing-qa' "$qa_dir/after.app/Contents/Info.plist"
./scripts/sign-app.sh "$qa_dir/after.app"

for version in before after; do
    codesign -d -r- "$qa_dir/$version.app" 2>&1 | sed -n 's/^designated => //p' > "$qa_dir/$version.req"
    test -s "$qa_dir/$version.req"
    codesign -d --verbose=4 "$qa_dir/$version.app" 2>&1 | sed -n 's/^CDHash=//p' > "$qa_dir/$version.hash"
    test -s "$qa_dir/$version.hash"
done
cmp "$qa_dir/before.req" "$qa_dir/after.req"
if cmp -s "$qa_dir/before.hash" "$qa_dir/after.hash"; then
    echo "错误：验证必须使用内容哈希不同的两个版本。" >&2
    exit 1
fi
codesign --verify --strict -R "$qa_dir/before.req" "$qa_dir/after.app"
codesign --verify --strict -R "$qa_dir/after.req" "$qa_dir/before.app"

# 配置错误应直接失败，不能悄悄更换签名身份。
if CODE_SIGN_IDENTITY=- ./scripts/sign-app.sh "$qa_dir/after.app" >/dev/null 2>&1; then
    echo "错误：不应允许临时签名。" >&2
    exit 1
fi
if CODE_SIGN_IDENTITY=ipaste-nonexistent-signing-identity ./scripts/sign-app.sh "$qa_dir/after.app" >/dev/null 2>&1; then
    echo "错误：不存在的签名身份应使构建失败。" >&2
    exit 1
fi
codesign --verify --strict -R "$qa_dir/before.req" "$qa_dir/after.app"

# 同 Bundle ID 的临时签名程序不能冒用固定证书身份。
codesign --force --sign - "$qa_dir/after.app" >/dev/null 2>&1
if codesign --verify --strict -R "$qa_dir/before.req" "$qa_dir/after.app" >/dev/null 2>&1; then
    echo "错误：固定身份校验不应接受临时签名。" >&2
    exit 1
fi
echo "签名回归验证通过：不同版本互认身份，拒绝临时签名和无效配置。"
