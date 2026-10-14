# 并行会话

使用完整的 `CODEX_THREAD_ID` 作为会话 ID。拿不到时，生成一次 `YYYYMMDD-HHmmss-<6位随机十六进制>`，并在整个会话中复用。

## 规则

- 涉及领域判断的工作开始前先读 `docs/agents/domain.md`。
- 会话私有产物使用 `<主题>.<会话ID>` 或 `<会话ID>/` 目录。
- 规格、工单、报告和跟踪 Issue 写上 `Codex-Thread: <会话ID>`。
- 以明确的来源规格或工单为准，不按分支或话题猜测。
- 写共享文件前立即重读；发现并发修改冲突就停止。
- 两个进行中的会话不得在同一工作区修改或提交。

## 生成的 macOS App

构建和无界面原生验证结束后，核对 bundle 身份和正在运行的可执行路径，再删除本次会话生成的 App 包以及 Release 构建路径中的 App 包。保留已安装的 `/Applications/TranslateApp.app` 和打包产物 `dist/TranslateApp.zip`。不删除源码、偏好、整个构建目录或正在运行的 App。
