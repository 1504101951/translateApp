# macOS 安装

运行 `./scripts/package-and-install-macos.sh` 完成打包并安装。脚本先写出并校验 `dist/TranslateApp.zip`，成功后才安装；失败立即退出。打包前保存内容并退出所有 TranslateApp；仍有 `translate_app` 进程时脚本停止。

## 可直接启动的 App

`scripts/package-and-install-macos.sh` 构建前删除本机已有副本，再签名并验证 Release App，生成 `dist/TranslateApp.zip`。随后在暂存目录解压并验签，安装到 `/Applications/TranslateApp.app`（访达「应用程序」）并注册 LaunchServices。可双击安装后的 App，或从 Spotlight 搜索 TranslateApp。

打包会先删除 `/Applications/TranslateApp.app`。安装前验证签名、检查归档和目标 Bundle ID，并把新 ZIP 安装到该路径。打包开始时已经删除的副本，安装失败后不会恢复。偏好保存在 UserDefaults，脚本不清理偏好。

## 辅助功能授权与签名

打包会重新签封外层 App，再执行完整签名校验，使外层资源摘要与 Flutter 生成的 App.framework 一致。使用固定身份先签名嵌套动态库和框架，再签名App。本地证书关闭时间戳，Developer ID身份启用安全时间戳。

辅助功能由 macOS TCC 管理。Bundle ID 为 `com.coolyang.translateApp`；macOS 同时校验代码签名的 designated requirement。

ad-hoc 签名的 requirement 可能直接绑定 `cdhash`。构建内容改变后代码哈希改变，已有授权可能不再适用，表现为系统开关已打开但 App 无法读取选区。仅固定安装路径或构建 Release 无法保证更新后保留授权。

持续使用同一稳定代码签名身份、Bundle ID 和安装位置，可以让系统识别连续更新的同一应用。提供有效证书时：

```sh
TRANSLATEAPP_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' ./scripts/package-and-install-macos.sh
```

脚本从内到外签名 Flutter frameworks 和 App，验证成功后才输出产物；默认使用 `TranslateApp Local Signing` 固定本地代码签名身份；证书/私钥不可用或显式指定ad-hoc时立即失败，不输出交付包。首次采用新的稳定身份仍需在系统设置重新授权一次。对其他 Mac 分发还需要相应签名及公证流程。

可用身份和实际 requirement 可通过以下命令核验：

```sh
security find-identity -v -p codesigning
codesign -d -r- --verbose=4 /Applications/TranslateApp.app
```

App 不修改 TCC 数据库，也不添加只匹配 Bundle ID 的宽松自定义 requirement。

## 旧 App 副本

打包开始前清除本机 `TranslateApp.app` 与 `translate_app.app`。废纸篓里的重名副本带时间戳后缀，同样按 Bundle ID 删除。Spotlight 查找已索引副本。另外直接检查 `/Applications/TranslateApp.app` 和 `~/Applications/TranslateApp.app`。`find` 只扫描 `~/.Trash`、`~/Library/Developer/Xcode/DerivedData`、仓库 `build/`、仓库 `dist/`、`/tmp`、`/private/tmp` 和 `/var/folders`。只删除 Bundle ID 为 `com.coolyang.translateApp` 的包；没有 Info.plist 时，仅当可执行文件是 `translate_app` 才删除。同一 Bundle ID 在 LaunchServices 中的登记会注销，包括文件已经不在的测试副本和打包暂存副本。本次注销过登记时才压缩数据库。不删除源码、偏好、整个 DerivedData、整个 build 目录、ZIP 或 Time Machine 备份。

正在运行的副本不删除。脚本退出时注销并删除本次暂存目录和 `build/macos/Build/Products/Release/translate_app.app`，避免新的暂存路径留在启动服务里。交付目录只保留 `dist/TranslateApp.zip`。

脚本在打包前按 Bundle ID 删除 `~/Applications/TranslateApp.app`，安装完成后再检查一次，避免用户目录和「应用程序」各留一份。


## 本机固定签名

在登录钥匙串保留名为 `TranslateApp Local Signing` 的代码签名证书及其私钥；后续构建不得重新生成同名但不同私钥的证书。无需导出或提交私钥。运行 `./scripts/package-and-install-macos.sh` 默认使用该身份；证书不可用时先报错，不回退到临时签名。

验收固定签名使用两个不同内容的构建：两者主可执行哈希可以不同，但 `codesign -d -r-` 的 designated requirement 应一致，且不得含内容绑定的 `cdhash` 条件；再执行 strict 验签。首次从临时签名切换后由用户重新授权一次；权限跨版本保持效果由用户验收，应用不修改TCC数据库。

若 `security find-identity -p codesigning` 能列出该身份但标记 `CSSMERR_TP_NOT_TRUSTED`，说明证书与私钥已匹配；由用户在钥匙串访问的证书“信任”中仅设置“代码签名”为“始终信任”。不能据此判断私钥缺失，也不需要重新创建证书。有效身份应出现在 `security find-identity -v -p codesigning` 中。
