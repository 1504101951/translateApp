#!/bin/bash
# 无参数；清除旧副本后构建并校验 Release ZIP，成功后再安装到访达「应用程序」。
# TRANSLATEAPP_SIGN_IDENTITY 可指定固定签名证书，缺省 TranslateApp Local Signing。
set -euo pipefail
cd "$(dirname "$0")/.."

built_app="build/macos/Build/Products/Release/translate_app.app"
archive="dist/TranslateApp.zip"
identity="${TRANSLATEAPP_SIGN_IDENTITY:-TranslateApp Local Signing}"
bundle_id="com.coolyang.translateApp"
target="/Applications/TranslateApp.app"
legacy="$HOME/Applications/TranslateApp.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# 打包暂存放在 dist 下，ZIP 才能在同一文件系统里原子替换。安装暂存放在临时目录，回滚时不碰已写好的 ZIP。
package_stage=""
install_stage=""
candidate_file=""
normalized_file=""
ordered_file=""
# 身份缺失立即失败，避免产出每次更新都会失去TCC授权的临时签名包。先于删除执行，证书不可用时不碰已安装副本。
if [[ "$identity" == "-" ]]; then
  echo "禁止ad-hoc交付；请配置固定代码签名证书。" >&2
  exit 1
fi
identities="$(security find-identity -v -p codesigning)"
if ! /usr/bin/grep -Fq "\"$identity\"" <<< "$identities"; then
  echo "未找到有效代码签名身份：$identity。请在钥匙串中完成证书和私钥配置。" >&2
  exit 1
fi
# 运行中的包删不干净，签名也会继续指向旧进程。
if pgrep -x translate_app >/dev/null; then
  echo "请先退出所有 TranslateApp，再打包。" >&2
  exit 1
fi

# 作用：判断路径最后一级是不是本仓库的 App 包名。
# 参数：app 为任意路径。
# 返回：0 表示包名是 TranslateApp.app、translate_app.app，或废纸篓重名后追加的「空格 + 时间戳」；大小写不敏感。1 表示不是。
is_target_app_name() {
  local base
  base="$(basename "$1")"
  base="$(printf '%s' "$base" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$base" == "translateapp.app" || "$base" == "translate_app.app" ]] && return 0
  # 废纸篓遇到重名会把副本改成 “TranslateApp 20-46-05-824.app”。
  [[ "$base" == translateapp\ *.app || "$base" == translate_app\ *.app ]]
}

# 作用：判断磁盘上的目录是否属于本应用，避免误删同名包。
# 参数：app 为已存在的 .app 目录。
# 返回：0 表示应删除；1 表示跳过。Bundle ID 匹配，或没有 Info.plist 但可执行文件是 translate_app 时删除。
should_remove_app() {
  local app="$1"
  local id
  # is_target_app_name：只接受打包名和 Flutter 产物名。
  is_target_app_name "$app" || return 1
  [[ -d "$app" ]] || return 1
  id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$id" == "$bundle_id" ]]; then
    return 0
  fi
  # 测试中断会留下没有 Info.plist 的半成品，只认本仓库可执行文件。
  [[ -z "$id" && -f "$app/Contents/MacOS/translate_app" ]]
}

# 作用：列出磁盘和 LaunchServices 中的候选路径。
# 参数：无。
# 返回：标准输出每行一个路径。Spotlight 负责已索引副本。固定安装路径直接判断。find 只补索引经常漏掉的废纸篓、DerivedData、本仓库产物和临时目录。
list_app_candidates() {
  mdfind "kMDItemCFBundleIdentifier == '${bundle_id}'" 2>/dev/null || true
  mdfind 'kMDItemFSName == "TranslateApp.app" || kMDItemFSName == "translate_app.app"' 2>/dev/null || true
  local path root
  # 这两个位置是安装目标。直接判断，避免遍历整个 /Applications。
  for path in /Applications/TranslateApp.app "$HOME/Applications/TranslateApp.app"; do
    if [[ -e "$path" ]]; then
      printf '%s\n' "$path"
    fi
  done
  for root in \
    "$HOME/.Trash" \
    "$HOME/Library/Developer/Xcode/DerivedData" \
    "$PWD/build" \
    "$PWD/dist" \
    /private/tmp \
    /tmp \
    /var/folders
  do
    [[ -d "$root" ]] || continue
    # 第三、四种名字是废纸篓为重名副本追加的时间戳，Spotlight 经常不索引这些路径。
    find "$root" \( -iname 'TranslateApp.app' -o -iname 'translate_app.app' -o -iname 'TranslateApp *.app' -o -iname 'translate_app *.app' \) -prune -print 2>/dev/null || true
  done
  # 目录删除后启动服务仍保留测试副本和 dist/package.* 暂存路径，屏幕录制列表会继续显示它们。
  "$lsregister" -dump 2>/dev/null | /usr/bin/awk -v bundle="$bundle_id" '
    function emit() {
      if (matched && path != "") print path
    }
    /^--------------------------------------------------------------------------------$/ { emit(); path=""; matched=0; next }
    /^path:[[:space:]]/ {
      line = $0
      sub(/^path:[[:space:]]+/, "", line)
      sub(/[[:space:]]+\(0x[0-9A-Fa-f]+\)$/, "", line)
      path = line
      next
    }
    /^identifier:[[:space:]]/ {
      if ($2 == bundle) matched = 1
      next
    }
    END { emit() }
  '
}

# 作用：注销并删除一个已核对的应用副本。
# 参数：app 为 .app 路径。目录不存在时只注销 LaunchServices。
# 返回：无。目录仍在时以非零状态退出。当前用户删不掉时请求管理员权限。成功注销后把外层 removed_registration 置为 1。
remove_app_copy() {
  local app="$1"
  local escaped
  if [[ -d "$app" ]]; then
    echo "删除旧副本：$app"
    "$lsregister" -u "$app" >/dev/null 2>&1 || true
    removed_registration=1
    if ! rm -rf "$app" 2>/dev/null; then
      escaped="$(printf '%q' "$app")"
      osascript -e "do shell script \"/bin/rm -rf -- $escaped\" with administrator privileges"
    fi
    if [[ -e "$app" ]]; then
      echo "无法删除：$app" >&2
      exit 1
    fi
    return 0
  fi
  echo "注销已不在磁盘上的登记：$app"
  "$lsregister" -u "$app" >/dev/null 2>&1 || true
  removed_registration=1
}

# 作用：清除本机旧副本和启动服务里的残留登记。
# 参数：无。读写外层 candidate_file、normalized_file、ordered_file、removed_registration。
# 返回：无。找不到副本时照常继续打包，且不压缩 LaunchServices 数据库。
remove_existing_copies() {
  local path line physical
  removed_registration=0
  echo "正在查找本机 TranslateApp 与 translate_app 副本…"
  candidate_file="$(mktemp)"
  normalized_file="$(mktemp)"
  ordered_file="$(mktemp)"
  # list_app_candidates：汇总磁盘路径和 LaunchServices 登记。
  list_app_candidates > "$candidate_file"
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    if [[ -d "$path" ]]; then
      physical="$(cd "$path" && pwd -P)" || physical="$path"
    else
      physical="$path"
    fi
    printf '%s\n' "$physical"
  done < "$candidate_file" | sort -u > "$normalized_file"
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    printf '%07d %s\n' "${#path}" "$path"
  done < "$normalized_file" | sort -nr > "$ordered_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    path="${line:8}"
    [[ -n "$path" ]] || continue
    case "$path" in
      /Volumes/.timemachine/*|*/Backups.backupdb/*|*/.MobileBackups/*)
        echo "跳过备份卷：$path" >&2
        continue
        ;;
    esac
    if [[ -d "$path" ]]; then
      # should_remove_app：只放行本应用包。remove_app_copy：注销并删除。
      if should_remove_app "$path"; then
        remove_app_copy "$path"
      else
        echo "跳过非本应用副本：$path" >&2
      fi
    elif is_target_app_name "$path"; then
      # is_target_app_name：缺失路径只注销这两种包名。remove_app_copy：目录不在时只注销。
      remove_app_copy "$path"
    fi
  done < "$ordered_file"
  # -u 读不到已删除的 bundle；只有这次注销过，才压缩数据库丢掉这些登记。
  if [[ "$removed_registration" == 1 ]]; then
    "$lsregister" -gc >/dev/null
  fi
}

# 作用：把 bundle 安装到目标路径。
# 参数：src 为待安装 bundle，dest 为访达「应用程序」目标。
# 返回：0 表示已写入。当前用户写不进去时请求管理员权限；管理员权限失败则命令失败。
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

# 作用：退出时先回滚安装，再清掉打包暂存和构建产物。
# 参数：无。使用外层 install_stage、package_stage、built_app 和临时列表文件。
# 返回：以进入 trap 时的状态码退出。回滚或删除暂存成功不能把失败变成成功退出。
cleanup_on_exit() {
  local status=$?
  # install_bundle：安装失败时把替换前的 App 装回去。打包开始时已删掉的副本不在 previous 里。
  if [[ "$status" != 0 && -n "$install_stage" && -d "$install_stage/previous" ]]; then
    install_bundle "$install_stage/previous" "$target" || true
  fi
  if [[ -n "$install_stage" ]]; then
    rm -rf "$install_stage"
  fi
  if [[ -n "$package_stage" && -d "$package_stage/TranslateApp.app" ]]; then
    "$lsregister" -u "$package_stage/TranslateApp.app" >/dev/null 2>&1 || true
  fi
  if [[ -d "$built_app" ]]; then
    "$lsregister" -u "$PWD/$built_app" >/dev/null 2>&1 || true
  fi
  if [[ -n "$package_stage" ]]; then
    rm -rf "$package_stage"
  fi
  rm -rf "$built_app"
  [[ -n "$candidate_file" ]] && rm -f "$candidate_file"
  [[ -n "$normalized_file" ]] && rm -f "$normalized_file"
  [[ -n "$ordered_file" ]] && rm -f "$ordered_file"
  exit "$status"
}
# 只注册一次 EXIT。后注册的 trap 会替换先注册的，分开清理会留下另一个暂存目录。
trap cleanup_on_exit EXIT

# remove_existing_copies：打包前清掉测试副本和旧安装，避免启动服务继续打开旧路径。
remove_existing_copies

# 每次从空目录打包，避免已移除的资源残留并破坏签名。
mkdir -p dist
package_stage="$(mktemp -d dist/package.XXXXXX)"
flutter build macos --release
ditto "$built_app" "$package_stage/TranslateApp.app"
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
done < <(find "$package_stage/TranslateApp.app/Contents" -type f -name '*.dylib' -print0)
for framework in "$package_stage/TranslateApp.app/Contents/Frameworks/"*.framework; do
  codesign "${sign_flags[@]}" "$framework"
done
# Flutter 可独立更新 App.framework；重新签封外层 App，使嵌套资源摘要与实际内容一致。
codesign "${sign_flags[@]}" --entitlements macos/Runner/Release.entitlements "$package_stage/TranslateApp.app"
codesign --verify --deep --strict "$package_stage/TranslateApp.app"
requirement="$(codesign -d -r- "$package_stage/TranslateApp.app" 2>&1)"
printf '%s\n' "$requirement"
# 权限身份必须由证书链与Bundle ID定义，不能再绑定某次构建的内容哈希。
if /usr/bin/grep -q 'designated.*cdhash' <<< "$requirement"; then
  echo "签名身份仍绑定cdhash，拒绝发布。" >&2
  exit 1
fi
ditto -c -k --sequesterRsrc --keepParent "$package_stage/TranslateApp.app" "$package_stage/TranslateApp.zip"
# 暂存文件位于同一文件系统，重命名原子替换已验证的归档。
mv -f "$package_stage/TranslateApp.zip" "$archive"
echo "Archive: $PWD/$archive"

# 构建可能耗时较久，开始安装前再确认没有新的 translate_app 进程。
if pgrep -x translate_app >/dev/null; then
  echo "请先从菜单栏退出 TranslateApp，再运行安装。" >&2
  exit 1
fi
install_stage="$(mktemp -d "${TMPDIR:-/tmp}/translateapp-install.XXXXXX")"
ditto -x -k "$archive" "$install_stage"
codesign --verify --deep --strict "$install_stage/TranslateApp.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$install_stage/TranslateApp.app/Contents/Info.plist")" == "$bundle_id" ]] || {
  echo "归档包含其他应用，停止安装。" >&2
  exit 1
}

if [[ -e "$target" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")" == "$bundle_id" ]] || {
    echo "目标位置存在其他应用，停止安装。" >&2
    exit 1
  }
  mv "$target" "$install_stage/previous" 2>/dev/null || {
    ditto "$target" "$install_stage/previous"
    rm -rf "$target" 2>/dev/null || osascript -e "do shell script \"/bin/rm -rf '$target'\" with administrator privileges"
  }
fi
# install_bundle：把验签后的包写入访达「应用程序」。
install_bundle "$install_stage/TranslateApp.app" "$target"
# 用户目录那份不会出现在访达「应用程序」里，留下会让录屏列表对不上正在运行的副本。
if [[ -d "$legacy" ]]; then
  legacy_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$legacy/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$legacy_id" == "$bundle_id" ]]; then
    "$lsregister" -u "$legacy" >/dev/null || true
    rm -rf "$legacy"
  fi
fi
"$lsregister" -f "$target"
echo "已安装：$target"
open -R "$target"
