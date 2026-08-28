# Issue tracker: GitHub Issues

Specs and issues for this repository live in GitHub Issues. Use the `gh` CLI for tracker operations.

## Conventions

- Create issues with `gh issue create`.
- Read issues and comments with `gh issue view <number> --comments`.
- List issues with `gh issue list` and request structured JSON when filtering.
- Comment with `gh issue comment <number>`.
- Apply or remove labels with `gh issue edit <number>`.
- Close issues with `gh issue close <number>`.
- Include `Codex-Thread: <session-id>` in every generated spec and ticket.
- Search for an existing issue with the same source and Codex thread before creating a duplicate.

## Pull requests as a triage surface

PRs are not part of the feature-request triage surface.
