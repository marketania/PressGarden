# AGENTS.md

## Product mission

WordPress maintenance, database health, cleanup, performance operations, caching, and LiteSpeed management.

## Engineering rules

- Read only the documentation relevant to the task. Use `docs/AI-DEVELOPMENT.md` for model/effort guidance and the repository architecture/migration docs when a change touches those boundaries.
- Treat database and cleanup operations as production mutations: validate scope, preflight, back up when required, confirm, apply, and verify. Never fabricate reclaimed-space or cleanup metrics, and never delete suspicious content as routine maintenance.
- Treat repository edits, pull requests, releases, and production website operations as distinct actions. Report only actions actually confirmed by tools.
- Keep this repository independently installable and runnable. Do not add a runtime dependency on either sibling tool.
- Keep secrets, client data, SQL dumps, evidence, and private state out of prompts, commits, issues, and test fixtures.
- Prefer small, reviewable changes. Preserve historical examples and changelogs unless the task explicitly updates history.

## Validation

Use `bash tests/run.sh` for local benign-fixture coverage. Database/LiteSpeed mutations require focused backup, verification, target-isolation, and isolated WordPress/MySQL recovery checks before merge.

For reversible documentation-only changes, use focused validation rather than unrelated exhaustive testing unless repository policy or CI requires more.
