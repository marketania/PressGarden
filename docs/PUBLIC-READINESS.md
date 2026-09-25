# PressGarden public-readiness audit

Scope: the standalone CLI, targeting, maintenance/policy mutation safeguards, installation/update/uninstall, private-state behavior, documentation, development configuration and CI/release distribution. This is a maintainer audit, not an independent certification or a promise that all bugs are absent.

## Confirmed defects corrected for 0.1.1

- Explicitly empty or invalid `sites` directory arguments now stop with exit 2 instead of falling back to fleet inventory.
- Directory targets retain exclusions relative to the original fleet root; discovery cache keys include that scope.
- Uninstall refuses update/recovery markers, including dangling symlinks, before changing managed files.
- Cleanup treats excluded nested installations as traversal boundaries, so a selected parent cannot clean an excluded child.

The new `tests/public-boundaries.py` reproduces these conditions using inert temporary WordPress layouts, a benign mock preference adapter and a real held `flock`. No client website is used. Product-specific cases are skipped in unrelated tools.

## Distribution and brand

The approved three-shield panel is a normal repository-local 700-pixel WebP in `docs/assets/press-tool-family.webp`, shown at the top of the README with alternative text. It is a compressed display derivative of the approved generated image, not replacement artwork or an embedded-data SVG. An offline checksum test protects it from accidental corruption.

Project `.codex/config.toml` uses top-level model settings. The old `[models.new_thread]` table belongs to administrator-managed `requirements.toml`; repository tests previously did not detect this mistake. The CLI still has no runtime OpenAI dependency.

All referenced GitHub actions are pinned to full commit IDs. Dependabot proposes dependency updates but never merges them. CODEOWNERS routes review but does not enforce branch protection. Exact-commit release gates remain intact, and old published tags/assets are not overwritten.

## Validation and evidence

Run `bash tests/run.sh` for bounded local fixture tests and syntax checks. CI adds ShellCheck error diagnostics, PHP 8.2/8.3/8.4/8.5 contracts, retained legacy PHP 7.4 compatibility, and isolated WordPress/MySQL integration. PressGarden additionally has a real disposable-database backup/restore drill. Consult PR and exact-main Actions results for the tested commit and outcomes; a new workflow definition alone is not proof it passed.

The audit began with 48 passing fixture scripts in PressWarden, 22 in PressHarden and 18 in PressGarden. Green baseline tests did not cover the defects above. Regression probes reproduced the failures before fixes and are now included in the test runner.

## Production prerequisites

Use Linux, Bash 4+, the documented GNU utilities, current security-patched supported PHP and the relevant WP-CLI/database clients. PHP 8.2–8.5 are supported at the audit date. PHP 7.4 is end-of-life despite legacy syntax tests; check upstream support before deploying. Web PHP can differ from CLI PHP.

Run as the site owner, keep private configuration/state/backups outside webroots, inspect discovery/exclusions, and begin on one isolated staging site. Retain independent off-host backups and test restoration of your own files and data before risky work. A SQL checksum is not a restore test; selected-table dumps are not complete website backups, and concurrent/nontransactional writes may require host snapshots or quiescence.

Stop other administration before update, uninstall or mutation. Per-product locks are not a distributed cross-product lock. The uninstall marker check does not coordinate every possible external writer. WordPress bootstrap, including MU-plugins, executes trusted PHP; it is not a sandbox. Preserve incident evidence before policy or maintenance work.

Do not schedule unattended mutations until manual staging validation has passed and the target, backup scope, exit codes and logs have been reviewed. Interrupted writes can leave partial effects; inspect current state before retrying. No production website/database, installed server tool, cron job or update preference was changed by this audit.

## Environment-specific acceptance checks

Actual client restore drills, effective web PHP, HTTP cache hits/CDN behavior, credentialed external APIs, hosting permissions/engines/concurrency, and organization branch-protection requirements remain environment-specific. Public use should follow the safeguards above, not a blanket claim of universal production certification.

## References

- [PHP supported versions](https://www.php.net/supported-versions.php)
- [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use)
- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Migration](MIGRATION.md) and [updating/recovery](UPDATING.md)
