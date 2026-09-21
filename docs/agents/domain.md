# Domain Docs

This is a single-context repository. Domain documentation lives at the repository root.

## Before exploring

- Read `CONTEXT-MAP.md` if it exists.
- Read the shared `CONTEXT.md` if it exists.
- Read `CONTEXT.<topic>.<thread-id>.md` for the current thread, then other `CONTEXT.*.md` files to detect terminology conflicts.
- Read relevant ADRs under `docs/adr/` if they exist.

Missing domain files do not block work and should not be created speculatively.

## Coding conventions

Shared channel names, method names, preference keys, and state enums live in `lib/src/common/constants/` and `macos/Runner/Common/Constants.swift`. See `docs/agents/coding-conventions.md`.

## Vocabulary

Use canonical terms from the context files consistently. If context files define the same term differently, stop and ask which definition governs instead of silently choosing one.

## ADR conflicts

Surface any conflict with an existing ADR explicitly instead of silently overriding it.

## 规格分类

开始需求、UI或架构工作前读取[三类规格索引](../specs/README.md)。功能与交互、样式、架构设计约束分别维护；当前实现说明和上下文记录不替代Spec。
