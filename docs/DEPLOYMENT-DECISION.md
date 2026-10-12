# Build and deployment decision

Owner decision dated **2026-10-11**. This records the chosen architecture,
not a verified implementation or authorization to activate it.

## Shared mobile architecture

- Use **GitHub Free / GitHub Actions** for mobile production builds and signing:
  Android on standard Linux runners; iOS on standard macOS runners.
- GitHub Pro, Xcode Cloud and paid CI are not required. Keep paid usage disabled;
  do not upgrade plans, enable paid overages or select paid/larger runners.
- Included usage is finite. Applicable account-level minute/artifact allowances
  are shared across the owner's repositories; verify current visibility, plan,
  runner accounting and remaining allowance before an authorized build. Do not
  promise unlimited usage or 2,000 macOS minutes. Stop when allowances cannot
  support a build; do not silently enable payment.
- Future mobile release workflows must be manual and main-only, use repository
  secrets, and retain required checks, review and action-time approvals.
- Credential entry and signing material require secure owner handling. Never
  paste secrets into repository files, chats, logs, commits or PRs.
- Apple Developer Program membership remains required for App Store/TestFlight.
  No public store release may occur without explicit owner approval.

## Scope for this repository

This is an independent Bash/PHP Press tool, not a mobile app. Record the shared
mobile decision for Codex and Claude without adding mobile workflows or changing
existing CLI packaging/source-release rules. Web-only projects retain their own
hosting and deployment rules; this decision does not prescribe a new web host.

**Product development remains parked until migration is verified and the owner
resumes it.** This documentation task is not evidence that migration is complete.

## Readiness and authorization

Choosing this architecture does not establish that signing identities,
certificates/profiles, membership, repository secrets, main-only workflow guards,
permissions, quota controls, workflows or deployments are ready. Record missing
setup as owner actions rather than completed features. Existing deployment,
migration and review safeguards remain in force.

This decision does not authorize merging, deploying, activating workflows,
changing permissions or billing, configuring credentials, or releasing to a store.

References for later owner verification: [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [Apple Developer membership](https://developer.apple.com/help/account/basics/about-your-developer-account).
