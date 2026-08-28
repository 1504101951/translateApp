# Domain Docs

This is a single-context repository. Domain documentation lives at the repository root.

## Before exploring

- Read `CONTEXT-MAP.md` if it exists.
- Read the shared `CONTEXT.md` if it exists.
- Read `CONTEXT.<topic>.<thread-id>.md` for the current thread, then other `CONTEXT.*.md` files to detect terminology conflicts.
- Read relevant ADRs under `docs/adr/` if they exist.

Missing domain files do not block work and should not be created speculatively.

## Vocabulary

Use canonical terms from the context files consistently. If context files define the same term differently, stop and ask which definition governs instead of silently choosing one.

## ADR conflicts

Surface any conflict with an existing ADR explicitly instead of silently overriding it.
