#!/bin/sh
# 打成稳定路径的 .app，辅助功能权限才能绑定到固定 bundle id。
set -e
cd "$(dirname "$0")/.."
swift build -c release --product TranslateApp
APP="dist/TranslateApp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TranslateApp "$APP/Contents/MacOS/TranslateApp"
cp TranslateApp/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - --identifier com.coolyang.TranslateApp "$APP"
echo "Built $APP"
