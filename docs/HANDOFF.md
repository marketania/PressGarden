# Handoff

Check this file and open pull requests before starting work. Record one branch and
owned area per agent/task. Resolve overlap through comments on the owning PR;
never push that agent's branch. Remove the entry when the PR is merged.

## Publication handoff — 0.1.2

The owner authorized publication on 2026-10-21. PR #15 consolidates unified
cleanup, readable fleet output, newcomer documentation and the reviewed safety
fixes from PR #9/#8. The release metadata includes the second-pass configuration,
scope and diagnostics fixes. The task ownership entry is removed with this merge.

The existing verified source-release workflow publishes only after the required
checks pass on the exact main commit. See [release notes](releases/0.1.2.md) for
operator changes and update instructions. Production website operations are
separate from source publication.

This is PressGarden, an independent Bash/PHP application. Runtime changes, client sites,
production credentials and deployment infrastructure are outside this setup.

Read [the 2026-10-11 build/deployment decision](DEPLOYMENT-DECISION.md) before any build/release planning.
