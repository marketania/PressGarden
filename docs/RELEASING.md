# Verified GitHub releases

Each repository publishes independently. A main-branch push with a new `VERSION` and matching `docs/releases/VERSION.md` is a release candidate. Every workflow listed in `.github/release-policy.json` must complete successfully on that exact commit. PR checks, previous commits, forks, skipped jobs and failed/pending workflows cannot satisfy the gate.

`Verified source release` is triggered by completion of each required main workflow. It checks that the upstream event was a push in this repository, checks the candidate is still the current main tip, verifies all required workflows, then packages **tracked Git source only**. It creates a draft, uploads the source tarball, `SOURCE.json`, `RELEASE_NOTES.md` and `SHA256SUMS`, checks upload sizes/digests when provided, and publishes only after successful uploads. The tag is `vVERSION` and targets the recorded commit, never a floating branch.

## Maintainer sequence

1. Review changes through a PR. Update VERSION and its release notes for a new release; update the policy/trigger list when adding CI workflows.
2. Merge only passing changes. The release gate waits for all required **main** checks, not merely PR checks.
3. Confirm the published tag, manifest and assets on the GitHub Releases page. Verify downloaded files with `sha256sum -c SHA256SUMS` from the asset directory.

Commits that do not change VERSION leave an existing published release and tag untouched. A mismatched pre-existing tag stops publication; tags are never force-moved. If an upload fails, a draft may remain: inspect it and the workflow logs before deliberately removing that unpublished draft and rerunning the release job. The matching lightweight tag can remain. Never delete or overwrite an already-published release as a retry shortcut.

The workflow has no scheduled release or server-deployment action. No SSH, host credentials, WordPress sites or client databases are accessed. Its GitHub token is repository-scoped, used only in the conditional trusted-main publishing job, and never printed. No PR artifact/cache is consumed. Offline release tests run under the existing read-only CI and cover trust boundaries, exact-commit gates, failure handling, packaging, checksums and trigger/policy consistency.

A GitHub release is not a production rollout. Installers/self-updaters retain their documented behavior; this workflow does not switch them to a different update channel or schedule. Review moved cron commands and relevant configuration before deploying the Press family split.
