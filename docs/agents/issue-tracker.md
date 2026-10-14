# Issue 跟踪：GitHub Issues

本仓库的规格与工单放在 GitHub Issues。跟踪操作使用 `gh` CLI。

## 约定

- 用 `gh issue create` 创建 Issue。
- 用 `gh issue view <编号> --comments` 阅读 Issue 和评论。
- 用 `gh issue list` 列出 Issue；筛选时请求结构化 JSON。
- 用 `gh issue comment <编号>` 发表评论。
- 用 `gh issue edit <编号>` 添加或移除标签。
- 不关闭 Issue；状态规则见 `AGENTS.md`。
- `Codex-Thread` 标记规则见 `docs/agents/session.md`。
- 创建前先搜索同一来源和同一 Codex 线程的已有 Issue，避免重复。

## 拉取请求

拉取请求不承担功能需求的分拣。

## 中文标签

标签使用：规格、规格：功能交互、规格：样式、规格：架构、功能、缺陷、文档、待实现、待验收、可开发、待澄清、无障碍、重复、无效、不予处理、适合新手、需要协助及优先级0–优先级3。待验收不表示用户已确认完成；失败反馈需评论记录，并标为待实现。

## 三类规格与执行工单

规格入口与本地副本保留规则见[docs/specs/README.md](../specs/README.md)。规格 Issue 使用“规格”加对应分类标签（规格：功能交互、规格：样式、规格：架构）。执行工单注明Source-Spec、Style-Spec、Architecture-Spec，功能工单挂到功能Spec下；样式和架构通过引用提供约束。

“可开发”对应已具备实施条件；含未定数值的工单标“待澄清”，列出具体参数后才能实施相关部分。不得把待澄清工单一律标成可开发。
