# GitHub collaboration

PressGarden is an independent Linux/Bash/PHP tool. These conventions coordinate Codex
and Claude through GitHub; they do not grant production access or authorize an
operation. Read [AGENTS.md](../AGENTS.md), [CLAUDE.md](../CLAUDE.md) and
[HANDOFF.md](HANDOFF.md) before starting work.

## Branches, reviews and handoff

Use one branch per agent/task: Codex owns `codex/`, Claude owns `claude/` or `fix/`.
Check the handoff and open PRs before claiming an area. Update only your branch;
comment on the other agent's PR to discuss overlapping work. Do not contact an
external Claude agent or share credentials. Remove your handoff entry when merged.

Use the [PR template](../.github/PULL_REQUEST_TEMPLATE.md). Keep commits and PRs
in normal English. List migrations, data-file changes, owner actions, tests and
risks explicitly, including `None` where appropriate. Screenshots are required
for UI changes; Arabic/mobile views apply only to relevant UI work.

An agent merges only its own PR after required CI passes and existing permissions
and server rules allow it. Claude/Codex peer review is optional for any PR, with
no owner waiver needed to skip it. This guidance does not authorize unrelated
merges, migrations, releases or deployments.

## Checks for this stack

Local dependencies: Bash 4+, PHP CLI 7.4+ with zlib, Python 3, Git, ShellCheck,
GNU timeout and the shell utilities already used by the repository. Use supported,
patched PHP for deployment; legacy syntax compatibility is not a hosting recommendation.

```bash
bash scripts/check.sh
```

The script fails immediately on missing dependencies, syntax or ShellCheck
errors, then runs the existing aggregate benign-fixture suite. The underlying
command remains:

```bash
bash tests/run.sh
```


Local fixtures use mocks and disposable paths. Never call live financial or
provider APIs from tests. The existing isolated WordPress/MySQL job and PHP
version matrix remain separate CI checks; a local pass does not certify those
jobs or a client's website. PressGarden also retains its authorized CI-only backup/restore drill; do not spoof GitHub CI authorization to run it locally.

The saved cloud host lacks native PHP and ShellCheck. CI already provides the
required tools; provision native development tools only through an approved
package source/environment workflow. Do not create credentials, change network
rules or treat blocked setup as completed. The earlier isolated WordPress
bootstrap attempt received proxy HTTP 403 for `api.wordpress.org`; live integration
is not verified in this cloud workspace.

## Labels

Use these six repository labels:

| Label | Meaning |
|---|---|
| `needs-review` | Optional peer review requested |
| `needs-migration` | Authorized migration required before dependent deployment |
| `ready-to-deploy` | Required checks complete; deployment still needs authorization |
| `blocked-owner` | Owner approval, credential/account or platform action is blocked |
| `codex` | Codex-authored work |
| `claude` | Claude-authored work or requested Claude review |

Use `codex`/`claude` for agent attribution. Apply `needs-review` and a reviewer
label only when optional peer review is requested. Labels do not grant
authorization or create a required merge gate.

## Proposed required checks on main

Proposal only; do not apply without specific action-time approval. For `main`,
require these existing CI job contexts, with strict up-to-date checks enabled:

```json
{
  "strict": true,
  "contexts": [
    "local",
    "PHP 8.2 contracts",
    "PHP 8.3 contracts",
    "PHP 8.4 contracts",
    "PHP 8.5 contracts",
    "php74",
    "wordpress"
  ]
}
```

This proposes additions to current rules; preserve every existing protection,
required check and release gate. Confirm the emitted context names on the final
PR commit before applying. The GitHub integration rejected reading main branch
protection with HTTP 403 (`Resource not accessible by integration`), so the owner
must review the existing rules and approve the exact additive change. No branch
protection or ruleset mutation has been made.

## Future migrations and deployment

These are CLI repositories, not Vercel apps. There is no new database migration,
locale, mobile or deployment stack in this setup. If future work introduces
migrations or data files, list them in the PR, obtain the required authorization,
apply and record migrations before dependent production deployment, and check
`main` for unapplied migrations immediately before deploying. Record the deployment
URL and health results afterward. For a CLI release without a URL, record the
release artifact/version and appropriate isolated smoke results instead of
inventing a hosted endpoint. Production auto-deploy is not enabled.

Owner actions: resolve blocked environment or
account setup through approved channels; confirm current main protection, and give separate action-time approval for protection changes
or any later production operation. No credentials or OAuth grants are created.
