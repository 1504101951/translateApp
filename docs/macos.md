# macOS 安装

运行 `./scripts/package-and-install-macos.sh` 完成打包并安装；失败立即退出。打包前保存内容并退出所有 TranslateApp；仍有 `translate_app` 进程时脚本停止。

## 可直接启动的 App

脚本构建前按 Bundle ID 删除本机已有副本（见下节），再签名并验证 Release App，写出 `dist/TranslateApp.zip`。在暂存目录解压、检查归档、验签并核对 Bundle ID 后，安装到 `/Applications/TranslateApp.app`（访达「应用程序」）并注册 LaunchServices；ZIP 校验成功才安装。打包开始时已删除的副本，安装失败后不会恢复。可双击安装后的 App，或从 Spotlight 搜索 TranslateApp。偏好保存在 UserDefaults，脚本不清理偏好。

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

打包开始前，脚本清除本机 `TranslateApp.app` 与 `translate_app.app` 的旧副本（含废纸篓里带时间戳后缀的重名副本）以及 `~/Applications/TranslateApp.app`，安装完成后再检查一次，避免用户目录和「应用程序」各留一份。扫描路径与匹配方式见 `scripts/package-and-install-macos.sh` 中的注释。

- 只删除 Bundle ID 为 `com.coolyang.translateApp` 的包；没有 Info.plist 时，仅当可执行文件是 `translate_app` 才删除。
- 正在运行的副本不删除。
- 同一 Bundle ID 在 LaunchServices 中的登记会注销，包括文件已不在的测试副本和打包暂存副本；本次注销过登记时才压缩数据库。
- 不删除源码、偏好、整个 DerivedData、整个 build 目录、ZIP 或 Time Machine 备份。
- 脚本退出时注销并删除本次暂存目录和 `build/macos/Build/Products/Release/translate_app.app`；交付目录只保留 `dist/TranslateApp.zip`。

## 本机固定签名

在登录钥匙串保留名为 `TranslateApp Local Signing` 的代码签名证书及其私钥；后续构建不得重新生成同名但不同私钥的证书。无需导出或提交私钥。运行 `./scripts/package-and-install-macos.sh` 默认使用该身份；证书不可用时先报错，不回退到临时签名。

验收固定签名使用两个不同内容的构建：两者主可执行哈希可以不同，但 `codesign -d -r-` 的 designated requirement 应一致，且不得含内容绑定的 `cdhash` 条件；再执行 strict 验签。首次从临时签名切换后由用户重新授权一次；权限跨版本保持效果由用户验收，应用不修改TCC数据库。

若 `security find-identity -p codesigning` 能列出该身份但标记 `CSSMERR_TP_NOT_TRUSTED`，说明证书与私钥已匹配；由用户在钥匙串访问的证书“信任”中仅设置“代码签名”为“始终信任”。不能据此判断私钥缺失，也不需要重新创建证书。有效身份应出现在 `security find-identity -v -p codesigning` 中。
