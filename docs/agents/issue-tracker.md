# Issue tracker: GitHub Issues

Specs and issues for this repository live in GitHub Issues. Use the `gh` CLI for tracker operations.

## Conventions

- Create issues with `gh issue create`.
- Read issues and comments with `gh issue view <number> --comments`.
- List issues with `gh issue list` and request structured JSON when filtering.
- Comment with `gh issue comment <number>`.
- Apply or remove labels with `gh issue edit <number>`.
- Do not close issues. Record progress, unresolved findings and verification evidence using comments and Chinese labels only. Issue closure belongs to the user.
- Include `Codex-Thread: <session-id>` in every generated spec and ticket.
- Search for an existing issue with the same source and Codex thread before creating a duplicate.
- Shared channel names, method names, and preference keys belong in `common/constants`; see `docs/agents/coding-conventions.md`.

## Pull requests as a triage surface

PRs are not part of the feature-request triage surface.

## 中文标签

标签使用：规格、功能、缺陷、文档、待实现、待验收、可开发、待澄清、无障碍、重复、无效、不予处理、适合新手、需要协助及优先级0–优先级3。待验收不表示用户已确认完成；失败反馈需评论记录，并标为待实现。

## 三类规格与执行工单

规格入口为[docs/specs/README.md](../specs/README.md)。功能、样式、架构规格分别维护本地与GitHub对应正文，Issue使用“规格”加对应中文分类标签。执行工单注明Source-Spec、Style-Spec、Architecture-Spec，功能工单挂到功能Spec下；样式和架构通过引用提供约束。

“可开发”对应已具备实施条件；含未定数值的工单标“待澄清”，列出具体参数后才能实施相关部分。不得把待澄清工单一律标成可开发。
