# Parallel Sessions

Use the complete `CODEX_THREAD_ID` as the session ID. If it is unavailable, generate `YYYYMMDD-HHmmss-<random-6-hex>` once and reuse it for the whole session.

## Rules

- Read `docs/agents/domain.md` before domain-sensitive work.
- Session-private artifacts use `<topic>.<session-id>` or a `<session-id>/` directory.
- Specs, tickets, reports, and tracker issues include `Codex-Thread: <session-id>`.
- Prefer an explicit source spec or ticket over guessing by branch or topic.
- Re-read shared files immediately before writing and stop if concurrent edits conflict.
- Two active sessions must not modify or commit from the same worktree.
