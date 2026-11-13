#!/bin/bash
set -euo pipefail

app_dir="${1:?用法：sign-app.sh /path/to/OpenPaste.app}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Contents/Info.plist")"

# 配置了固定发布身份的开发机与 CI 复用同一证书，避免本机包和发行包交替更换身份。
# 显式 CODE_SIGN_IDENTITY 始终优先；未配置发布身份的开发机继续沿用原本机证书。
release_signing_dir="$HOME/Library/Application Support/OpenPaste/ReleaseSigning"
if [ -z "${CODE_SIGN_IDENTITY:-}" ] && [ -d "$release_signing_dir" ]; then
    release_keychain="$release_signing_dir/OpenPaste-Release.keychain-db"
    release_password_file="$release_signing_dir/keychain-password"
    release_certificate="$release_signing_dir/certificate.pem"
    if [ ! -f "$release_keychain" ] || [ ! -s "$release_password_file" ] || [ ! -s "$release_certificate" ]; then
        echo "错误：固定发布签名身份不完整：$release_signing_dir；请恢复原身份，不会回退到其他证书。" >&2
        exit 1
    fi
    CODE_SIGN_IDENTITY="$(openssl x509 -in "$release_certificate" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
    CODE_SIGN_KEYCHAIN="$release_keychain"
    release_keychain_password="$(cat "$release_password_file")"
    security unlock-keychain -p "$release_keychain_password" "$release_keychain"
    trap 'security lock-keychain "$release_keychain" >/dev/null 2>&1 || true' EXIT
fi

# 发布构建可传入 Apple Development / Developer ID 身份；指定失败时绝不回退到临时签名。
if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    if [ "$CODE_SIGN_IDENTITY" = "-" ]; then
        echo "错误：临时签名会导致更新后丢失辅助功能授权，请使用固定签名身份。" >&2
        exit 1
    fi
    sign_args=(--force --sign "$CODE_SIGN_IDENTITY" --identifier "$bundle_id")
    if [ -n "${CODE_SIGN_KEYCHAIN:-}" ]; then
        sign_args+=(--keychain "$CODE_SIGN_KEYCHAIN")
    fi
    codesign "${sign_args[@]}" "$app_dir"
else
    # 更名后沿用 iPaste 的签名目录、钥匙串和证书，保持已有辅助功能授权。
    # 固定身份存放在源码和 build 目录之外，清理或重新克隆项目不会更换身份。
    # 独立钥匙串仅保存本应用的签名密钥，不修改系统信任或辅助功能授权。
    umask 077
    signing_dir="$HOME/Library/Application Support/iPaste/CodeSigning"
    keychain="$signing_dir/iPaste.keychain-db"
    password_file="$signing_dir/keychain-password"
    certificate="$signing_dir/certificate.pem"
    mkdir -p "$signing_dir"
    chmod 700 "$signing_dir"

    if [ ! -e "$keychain" ] && [ ! -e "$password_file" ] && [ ! -e "$certificate" ]; then
        setup_dir="$(mktemp -d "$signing_dir/.setup.XXXXXX")"
        trap 'rm -rf "$setup_dir"' EXIT
        openssl rand -hex 32 > "$password_file"
        keychain_password="$(cat "$password_file")"
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$setup_dir/key.pem" -out "$certificate" -days 3650 \
            -subj '/CN=iPaste Local Code Signing/' -config /dev/stdin >/dev/null 2>&1 <<'CONF'
[req]
distinguished_name=dn
x509_extensions=ext
[dn]
[ext]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONF
        openssl pkcs12 -export -inkey "$setup_dir/key.pem" -in "$certificate" \
            -out "$setup_dir/identity.p12" -passout "pass:$keychain_password"
        security create-keychain -p "$keychain_password" "$keychain"
        security unlock-keychain -p "$keychain_password" "$keychain"
        security import "$setup_dir/identity.p12" -k "$keychain" \
            -P "$keychain_password" -T /usr/bin/codesign -x >/dev/null
        security set-key-partition-list -S apple-tool:,codesign: -s \
            -k "$keychain_password" "$keychain" >/dev/null
        rm -rf "$setup_dir"
        trap - EXIT
        echo "已创建固定的本机签名身份，后续构建将复用。"
    fi

    if [ ! -f "$keychain" ] || [ ! -s "$password_file" ] || [ ! -s "$certificate" ]; then
        echo "错误：本机签名身份不完整：$signing_dir；请恢复原身份，不要重新生成，以免丢失授权。" >&2
        exit 1
    fi
    keychain_password="$(cat "$password_file")"
    identity="$(openssl x509 -in "$certificate" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
    security unlock-keychain -p "$keychain_password" "$keychain"
    trap 'security lock-keychain "$keychain" >/dev/null 2>&1 || true' EXIT
    codesign --force --sign "$identity" --keychain "$keychain" \
        --timestamp=none --identifier "$bundle_id" "$app_dir"
fi

codesign --verify --strict "$app_dir"
