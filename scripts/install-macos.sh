#!/bin/bash
# 无参数；将已校验的 dist/TranslateApp.app 安装到固定用户应用目录，不删除偏好数据。
set -euo pipefail
cd "$(dirname "$0")/.."

source_app="$PWD/dist/TranslateApp.app"
target="$HOME/Applications/TranslateApp.app"
codesign --verify --deep --strict "$source_app"
if pgrep -x translate_app >/dev/null; then
  echo "请先从菜单栏退出 TranslateApp，再运行安装。" >&2
  exit 1
fi
mkdir -p "$HOME/Applications"
stage="$(mktemp -d "$HOME/Applications/.translateapp-install.XXXXXX")"
# 安装失败时恢复已有 App；成功后只清理本次暂存目录。
cleanup() {
  if [[ -d "$stage/previous" && ! -e "$target" ]]; then
    mv "$stage/previous" "$target"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
ditto "$source_app" "$stage/TranslateApp.app"
codesign --verify --deep --strict "$stage/TranslateApp.app"
if [[ -e "$target" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")" == "com.coolyang.translateApp" ]] || {
    echo "目标位置存在其他应用，停止安装。" >&2
    exit 1
  }
  mv "$target" "$stage/previous"
fi
mv "$stage/TranslateApp.app" "$target"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
echo "已安装：$target"

