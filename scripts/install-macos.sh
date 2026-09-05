#!/bin/bash
# 无参数；解压并校验 dist/TranslateApp.zip，安装到固定用户应用目录，不删除偏好数据。
set -euo pipefail
cd "$(dirname "$0")/.."

archive="$PWD/dist/TranslateApp.zip"
target="$HOME/Applications/TranslateApp.app"
if pgrep -x translate_app >/dev/null; then
  echo "请先从菜单栏退出 TranslateApp，再运行安装。" >&2
  exit 1
fi
mkdir -p "$HOME/Applications"
stage="$(mktemp -d "$HOME/Applications/.translateapp-install.XXXXXX")"
# 无参数、无返回值；安装失败时恢复已有 App，退出时清理本次暂存目录。
cleanup() {
  local install_status=$?
  if [[ "$install_status" != 0 && -d "$stage/previous" ]]; then
    rm -rf "$target"
    mv "$stage/previous" "$target"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
ditto -x -k "$archive" "$stage"
codesign --verify --deep --strict "$stage/TranslateApp.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$stage/TranslateApp.app/Contents/Info.plist")" == "com.coolyang.translateApp" ]] || {
  echo "归档包含其他应用，停止安装。" >&2
  exit 1
}
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
