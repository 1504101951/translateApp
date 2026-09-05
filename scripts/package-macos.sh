#!/bin/bash
# 无参数；构建独立 Release App。TRANSLATEAPP_SIGN_IDENTITY 可指定稳定证书；输出 dist/TranslateApp.app。
set -euo pipefail
cd "$(dirname "$0")/.."

app="dist/TranslateApp.app"
identity="${TRANSLATEAPP_SIGN_IDENTITY:--}"
flutter build macos --release

# 每次从空目录打包，避免已移除的资源残留并破坏签名。
mkdir -p dist
stage="$(mktemp -d dist/package.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
ditto build/macos/Build/Products/Release/translate_app.app "$stage/TranslateApp.app"
if [[ "$identity" != "-" ]]; then
  for framework in "$stage/TranslateApp.app/Contents/Frameworks/"*.framework; do
    codesign --force --sign "$identity" --options runtime --timestamp "$framework"
  done
  codesign --force --sign "$identity" --options runtime --timestamp \
    --entitlements macos/Runner/Release.entitlements "$stage/TranslateApp.app"
fi
codesign --verify --deep --strict "$stage/TranslateApp.app"
rm -rf "$app"
mv "$stage/TranslateApp.app" "$app"
codesign -d -r- "$app" 2>&1
if [[ "$identity" == "-" ]]; then
  echo "本机 ad-hoc 构建：更新后的辅助功能授权可能需要重新添加。稳定授权请配置固定签名证书。"
fi
echo "App: $PWD/$app"

