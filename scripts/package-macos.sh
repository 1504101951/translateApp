#!/bin/bash
# 无参数；构建并校验 Release App，输出 dist/TranslateApp.zip；环境变量可指定固定签名证书。
set -euo pipefail
cd "$(dirname "$0")/.."

built_app="build/macos/Build/Products/Release/translate_app.app"
archive="dist/TranslateApp.zip"
identity="${TRANSLATEAPP_SIGN_IDENTITY:--}"
if pgrep -f "^$PWD/$built_app/Contents/MacOS/translate_app([[:space:]]|$)" >/dev/null; then
  echo "请先退出直接从 build 运行的 TranslateApp，再打包。" >&2
  exit 1
fi

# 每次从空目录打包，避免已移除的资源残留并破坏签名。
mkdir -p dist
stage="$(mktemp -d dist/package.XXXXXX)"
# 只留下 ZIP 交付物，避免 Spotlight 收录构建副本；运行中的安装版不在清理范围。
trap 'rm -rf "$stage" "$built_app"' EXIT
flutter build macos --release
ditto "$built_app" "$stage/TranslateApp.app"
sign_flags=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  # 稳定证书统一嵌套代码身份；本机 ad-hoc 没有 Team ID，沿用 Flutter 的普通签名选项。
  sign_flags+=(--options runtime --timestamp)
  for framework in "$stage/TranslateApp.app/Contents/Frameworks/"*.framework; do
    codesign "${sign_flags[@]}" "$framework"
  done
fi
# Flutter 可独立更新 App.framework；重新签封外层 App，使嵌套资源摘要与实际内容一致。
codesign "${sign_flags[@]}" --entitlements macos/Runner/Release.entitlements "$stage/TranslateApp.app"
codesign --verify --deep --strict "$stage/TranslateApp.app"
codesign -d -r- "$stage/TranslateApp.app" 2>&1
ditto -c -k --sequesterRsrc --keepParent "$stage/TranslateApp.app" "$stage/TranslateApp.zip"
# 暂存文件位于同一文件系统，重命名原子替换已验证的归档。
mv -f "$stage/TranslateApp.zip" "$archive"
if [[ "$identity" == "-" ]]; then
  echo "本机 ad-hoc 构建：更新后的辅助功能授权可能需要重新添加。稳定授权请配置固定签名证书。"
fi
echo "Archive: $PWD/$archive"
