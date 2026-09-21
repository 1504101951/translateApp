#!/bin/bash
# 无参数；构建并校验 Release App，输出 dist/TranslateApp.zip；环境变量可指定固定签名证书。
set -euo pipefail
cd "$(dirname "$0")/.."

built_app="build/macos/Build/Products/Release/translate_app.app"
archive="dist/TranslateApp.zip"
identity="${TRANSLATEAPP_SIGN_IDENTITY:-TranslateApp Local Signing}"
# 身份缺失立即失败，避免产出每次更新都会失去TCC授权的临时签名包。
if [[ "$identity" == "-" ]]; then
  echo "禁止ad-hoc交付；请配置固定代码签名证书。" >&2
  exit 1
fi
identities="$(security find-identity -v -p codesigning)"
if ! /usr/bin/grep -Fq "\"$identity\"" <<< "$identities"; then
  echo "未找到有效代码签名身份：$identity。请在钥匙串中完成证书和私钥配置。" >&2
  exit 1
fi
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
if [[ "$identity" == "Developer ID Application:"* ]]; then
  # 对外分发身份使用安全时间戳；本地自签名证书不向时间戳服务请求公证能力。
  sign_flags+=(--options runtime --timestamp)
else
  sign_flags+=(--timestamp=none)
fi
# 从最内层签名实际动态库，再签框架与外层App，所有代码沿用同一身份。
while IFS= read -r -d '' library; do
  codesign "${sign_flags[@]}" "$library"
done < <(find "$stage/TranslateApp.app/Contents" -type f -name '*.dylib' -print0)
for framework in "$stage/TranslateApp.app/Contents/Frameworks/"*.framework; do
  codesign "${sign_flags[@]}" "$framework"
done
# Flutter 可独立更新 App.framework；重新签封外层 App，使嵌套资源摘要与实际内容一致。
codesign "${sign_flags[@]}" --entitlements macos/Runner/Release.entitlements "$stage/TranslateApp.app"
codesign --verify --deep --strict "$stage/TranslateApp.app"
requirement="$(codesign -d -r- "$stage/TranslateApp.app" 2>&1)"
printf '%s\n' "$requirement"
# 权限身份必须由证书链与Bundle ID定义，不能再绑定某次构建的内容哈希。
if /usr/bin/grep -q 'designated.*cdhash' <<< "$requirement"; then
  echo "签名身份仍绑定cdhash，拒绝发布。" >&2
  exit 1
fi
ditto -c -k --sequesterRsrc --keepParent "$stage/TranslateApp.app" "$stage/TranslateApp.zip"
# 暂存文件位于同一文件系统，重命名原子替换已验证的归档。
mv -f "$stage/TranslateApp.zip" "$archive"
echo "Archive: $PWD/$archive"
