# macOS 安装

## 可直接启动的 App

`scripts/package-macos.sh` 构建、签名并验证 Release App，生成 `dist/TranslateApp.zip`；`scripts/install-macos.sh` 在暂存目录解压并验签，安装到 `~/Applications/TranslateApp.app` 并注册 LaunchServices。可双击安装后的 App，或从 Spotlight 搜索 TranslateApp。

安装更新前从菜单栏退出 App，再执行安装脚本；构建 ZIP 可以保留已安装版本运行。安装脚本验证签名、检查归档和目标 Bundle ID，使用暂存目录替换整个 bundle，失败时恢复已有 App。偏好保存在 UserDefaults，安装不会清理偏好。

## 辅助功能授权与签名

打包会重新签封外层 App，再执行完整签名校验，使外层资源摘要与 Flutter 生成的 App.framework 一致。指定证书时先按相同身份签名嵌套框架。

辅助功能由 macOS TCC 管理。Bundle ID 为 `com.coolyang.translateApp`；macOS 同时校验代码签名的 designated requirement。

ad-hoc 签名的 requirement 可能直接绑定 `cdhash`。构建内容改变后代码哈希改变，已有授权可能不再适用，表现为系统开关已打开但 App 无法读取选区。仅固定安装路径或构建 Release 无法保证更新后保留授权。

持续使用同一稳定代码签名身份、Bundle ID 和安装位置，可以让系统识别连续更新的同一应用。提供有效证书时：

```sh
TRANSLATEAPP_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' ./scripts/package-macos.sh
./scripts/install-macos.sh
```

脚本从内到外签名 Flutter frameworks 和 App，验证成功后才输出产物；没有指定证书时使用本机 ad-hoc 构建。首次采用新的稳定身份仍需在系统设置重新授权一次。对其他 Mac 分发还需要相应签名及公证流程。

可用身份和实际 requirement 可通过以下命令核验：

```sh
security find-identity -v -p codesigning
codesign -d -r- --verbose=4 ~/Applications/TranslateApp.app
```

App 不修改 TCC 数据库，也不添加只匹配 Bundle ID 的宽松自定义 requirement。

## 旧 App 副本

打包脚本退出时清理本次暂存目录及 `build/macos/Build/Products/Release/translate_app.app`，交付目录只保留 ZIP。开发和原生测试产生的 Debug、Xcode DerivedData 及临时目录中的 `translate_app.app` 在验证结束后清理，仅删除经路径与 Bundle ID 核对的生成 App；不删除整个 DerivedData、源码或偏好文件。清理前确认目标副本没有运行。

日常启动入口只保留 `~/Applications/TranslateApp.app`；ZIP 归档不作为已安装应用登记。
