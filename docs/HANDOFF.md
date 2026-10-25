# Handoff

Check this file and open pull requests before starting work. Record one branch and
owned area per agent/task. Resolve overlap through comments on the owning PR;
never push that agent's branch. Remove the entry when the PR is merged.


## Publication handoff — 0.1.3

The owner asked to publish these changes on 2026-10-25. Version 0.1.3 releases
the per-category `Clean now?` prompt (PR #18) and `backups prune` (PR #16). No task ownership entry remains.

The existing verified source-release workflow publishes only after the required
checks pass on the exact main commit. See [release notes](releases/0.1.3.md) for
operator changes and update instructions. Production website operations are
separate from source publication.

This is PressGarden, an independent Bash/PHP application. Runtime changes, client sites,
production credentials and deployment infrastructure are outside this setup.

Read [the 2026-10-11 build/deployment decision](DEPLOYMENT-DECISION.md) before any build/release planning.
