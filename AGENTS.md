# 智能体工作规范

## Issue 跟踪

规格与执行工单统一在本仓库 GitHub Issues 中维护，操作约定见 [Issue 跟踪规则](docs/agents/issue-tracker.md)。

## 领域文档

本仓库采用单一领域上下文，阅读顺序与术语约定见 [领域文档规则](docs/agents/domain.md)。

## 代码约定

通道名、方法名、UserDefaults 键与共享枚举集中在 `common/constants`，共享工具集中在 `common/utils`；具体路径与使用规则见 [代码约定](docs/agents/coding-conventions.md)。

## 界面设计

设计、实现、重构或审查界面前，读取 [UI 规则入口](docs/agents/liquid-glass-ui.md) 并遵守其引用的共享规范；只有实际选用某个组件库时，才应用该库的专属 API 规则。

## 并行会话

使用完整 Codex 任务 ID 隔离临时产物并标记 Issue 输出，具体规则见 [会话隔离规范](docs/agents/session.md)。

## 先更新规格，再开发

开发依据分为三类：[功能与交互规格 #1](docs/specs/functional.md)、[样式规格 #67](docs/specs/style.md)、[架构设计约束 #68](docs/specs/architecture.md)。职责与同步规则见 [规格索引](docs/specs/README.md)。实施已批准需求前，先同步受影响的本地文档与 GitHub Spec；界面数值必须明确，不得擅自偏离规格或将待确认参数视为已批准值。

## 目录索引

项目维护的每个目录通过 `index.md` 说明直接子文件和子目录的作用，每项一句话；新增、删除或重命名项目文件时同步所在目录索引。Git 元数据、依赖缓存、构建产物及个人工作区目录不纳入索引。

## Issue 状态权限

智能体不得关闭 Issue；实现、测试和验收结果仅通过评论与中文标签记录。用户指出未完成时，按实际进度标记待实现或待验收并记录未完成项，不将已关闭状态视为验收通过。

## 验收方式

禁止使用 computer-use。界面效果验收由用户完成；智能体负责代码检查、自动化测试、构建与签名核验，不能把自动化通过等同于用户验收。
