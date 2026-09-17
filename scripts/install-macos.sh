#!/bin/bash
# 无参数；解压并校验 dist/TranslateApp.zip，安装到访达「应用程序」，不删除偏好数据。
set -euo pipefail
cd "$(dirname "$0")/.."

archive="$PWD/dist/TranslateApp.zip"
target="/Applications/TranslateApp.app"
legacy="$HOME/Applications/TranslateApp.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# src 为待安装 bundle，dest 为访达「应用程序」目标；写不进去时再要管理员权限。
install_bundle() {
  local src="$1"
  local dest="$2"
  if [[ -e "$dest" ]]; then
    rm -rf "$dest" 2>/dev/null || true
  fi
  if ditto "$src" "$dest" 2>/dev/null; then
    return 0
  fi
  osascript -e "do shell script \"/bin/rm -rf '$dest' && /usr/bin/ditto '$src' '$dest'\" with administrator privileges"
}

if pgrep -x translate_app >/dev/null; then
  echo "请先从菜单栏退出 TranslateApp，再运行安装。" >&2
  exit 1
fi
stage="$(mktemp -d "${TMPDIR:-/tmp}/translateapp-install.XXXXXX")"
# 无参数、无返回值；安装失败时恢复已有 App，退出时清理本次暂存目录。
cleanup() {
  local install_status=$?
  if [[ "$install_status" != 0 && -d "$stage/previous" ]]; then
    install_bundle "$stage/previous" "$target" || true
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
  mv "$target" "$stage/previous" 2>/dev/null || {
    ditto "$target" "$stage/previous"
    rm -rf "$target" 2>/dev/null || osascript -e "do shell script \"/bin/rm -rf '$target'\" with administrator privileges"
  }
fi
install_bundle "$stage/TranslateApp.app" "$target"
# 用户目录那份不会出现在访达「应用程序」里，留下会让录屏列表对不上正在运行的副本。
if [[ -d "$legacy" ]]; then
  legacy_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$legacy/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$legacy_id" == "com.coolyang.translateApp" ]]; then
    "$lsregister" -u "$legacy" >/dev/null || true
    rm -rf "$legacy"
  fi
fi
"$lsregister" -f "$target"
echo "已安装：$target"
open -R "$target"
