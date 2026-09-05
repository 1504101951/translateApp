# macOS 安装

## 可直接启动的 App

`scripts/package-macos.sh` 构建 Release，并生成 `dist/TranslateApp.app`；`scripts/install-macos.sh` 安装到 `~/Applications/TranslateApp.app` 并注册 LaunchServices。可双击该 App，或从 Spotlight 搜索 TranslateApp。

更新前从菜单栏退出 App，再执行打包和安装。安装脚本验证签名、检查目标 Bundle ID，使用暂存目录替换整个 bundle，失败时恢复已有 App。偏好保存在 UserDefaults，安装不会清理偏好。

## 辅助功能授权与签名

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

`build/macos/Build/Products/Debug/translate_app.app`、Xcode DerivedData 中的 `translate_app.app` 和临时测试目录中的同名 App 都是可再生成的构建产物。正式安装完成并退出旧进程后，可将这些 **App bundle** 移至废纸篓；无需删除仓库、整个 DerivedData 或偏好文件。

Spotlight 中的名字可能相同，应先在 Finder 查看路径。保留 `~/Applications/TranslateApp.app` 作为日常启动入口。

