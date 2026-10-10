# CLAUDE.md

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

## GitHub collaboration

- Read [the handoff](docs/HANDOFF.md) before work, check open PRs for overlap, and record your branch and owned area. Remove the entry when its PR is merged.
- Use one branch per agent/task. Codex uses `codex/`; Claude uses `claude/` or `fix/`. Never push another agent's branch; comment on its PR to coordinate. Coordination is through repository files, branches, PRs and labels only.
- Keep commits and PRs in normal English. Every PR lists migrations, data files, owner actions, tests and risks; include screenshots for UI changes, with Arabic/mobile views only where applicable.
- Run `bash scripts/check.sh` for fail-fast dependency, syntax, ShellCheck and benign-fixture validation. Tests must not call live financial or provider APIs. Real WordPress/MySQL checks belong only to explicitly isolated fixtures/CI.
- An agent may merge only its own PR after required CI passes and the other agent reviews, unless the owner explicitly waives review. Action-time approvals still apply: these instructions do not authorize a merge, deployment or production operation now.
- Apply and record authorized migrations before a dependent production deployment. Before any future deployment, check `main` for unapplied migrations; afterward record the deployment URL and health results. Do not invent a migration or hosting stack for this Bash/PHP tool.
- Preserve existing CI, release gates and production safeguards. Required checks and branch-protection changes are security-sensitive: propose exact changes and obtain specific action-time approval before applying them.
- Record blocked credential, account or platform setup as owner actions. Do not create credentials, OAuth grants, unsafe fork `pull_request_target` workflows, or production auto-deployment.

See [GitHub collaboration and proposed checks](docs/GITHUB-COLLABORATION.md). Product-specific rules above remain in effect. Keep this file and `CLAUDE.md` aligned.
