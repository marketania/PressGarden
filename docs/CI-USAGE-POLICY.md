# CI usage and publication policy

## Dated budget authorization (owner report, 2026-10-12)

The owner reports all 2,000 included Actions minutes consumed and an existing
$30 monthly overage cap. Paid GitHub Actions are explicitly authorized **only
through October 2026, within that existing $30 cap**. Do not increase the cap,
upgrade plans or treat this temporary authorization as a recurring permission.
This records the owner's report and authorization, not a verified billing state.

The intended paid limit is **$0 starting November 2026**. October authorization
expires at the end of October; the November billing guard has not been configured
or verified by this patch. From November, do not push/rerun/dispatch paid workloads
unless the coordinating parent confirms a $0 guard or a new explicitly dated
budget. Before each batch, confirm current authorization and available allowance.

Work locally and test offline first. No agent may change billing, permissions,
secrets or branch protection under this policy. Signing/store submission still
requires secure owner setup and separate action-time approval.

## Rules for Codex and Claude

- Batch commits into a reviewable work unit. Run applicable checks in the coding
  environment before one deliberate push; do not push every incremental AI edit.
- Record checks, failures and blocked dependencies accurately. Use the existing
  local entry point `bash scripts/check.sh` for code/CI changes and focused
  documentation checks when repository policy permits. Tests must not call live
  financial/provider APIs or client websites.
- Avoid duplicate feature-branch push and PR runs. Keep required merge contexts
  and trusted main release verification; never use skip-ci commit markers to
  bypass required checks.
- Cancel superseded checks for the same PR, with a workflow-specific concurrency
  group. Do not cancel unrelated workflows or production/release operations.
- Use narrow, cumulative changed-path classification. Unknown paths, code,
  tests, configuration, workflow edits, missing history and malformed events must
  keep full checks. Never classify only the last commit of a multi-commit PR.
- For docs-only PRs, skip expensive work inside workflows while still emitting
  every required check. Do not use workflow-level path filters that leave required
  checks pending. Preserve matrix context names as well as ordinary job names.
- Keep expensive mobile production builds manual and main-only, with the owner's
  existing release approvals. These Press tools are Bash/PHP CLI products;
  do not introduce mobile builds or change their verified source-release gates.
- Keep failed diagnostic artifacts short-lived. Preserve release symbols,
  signed release assets and source provenance for their approved retention needs;
  do not delete them as a cost-saving shortcut.

## Local patch for the Press repositories

Validation workflows retain main-push and PR-to-main triggers. Feature pushes do
not also trigger them. Main pushes and manual validation remain full checks to
preserve exact-commit source-release evidence. PR-only concurrency cancels older
runs of the same workflow/PR; main and manual runs use distinct run-ID groups.

`.github/scripts/ci_scope.py` permits only known documentation paths to take the
cheap PR route. The existing first job classifies a cumulative Git diff and stays
present. Primary docs-only checks run scope regressions and documentation,
distribution and public-distribution contracts. Specialized tests, legacy PHP,
MySQL/WordPress services and upstream corpus jobs are conditional. Every supported
PHP matrix context still starts a cheap marker job; its Docker work is skipped.
This avoids required-check deadlocks but retains some runner-start overhead.

Job IDs/names, PHP versions, test commands, permission scope, release workflows
and release-policy files remain intact. Failure logs upload only on failed full
runs and retain for one day. The source-release assets are untouched. No new
mobile workflow is added. This is CI maintenance explicitly requested by the
owner; it does not resume parked product development or verify migration.

The parent has confirmed the October authorization, so one locally checked batched
push and necessary CI are permitted within the existing cap. Verify GitHub check
contexts on the final PR commit before merge; agent peer review is optional. Offline validation
cannot certify hosted-runner expression behavior. Required-check or protection
changes need their own specific action-time approval; none are requested/applied
by this patch.
