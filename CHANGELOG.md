# Changelog

## 0.1.2 — 2026-10-21

### Consolidated commands and readable cleanup

- Rewrite the README around installation from selected source, site discovery, a first-site preview, everyday commands, result meanings and recovery. Explain selected releases and the rolling main installer/updater.
- Refuse malformed or failed saved configuration before command dispatch, report empty doctor scopes and invalid config roots as incomplete, and accept consistent named doctor targets.
- Preserve exported configuration values exactly, including multiline exclusions; never truncate invalid scan roots or silently discard an override blocked by a readonly saved setting.
- Add focused database/cache/status help, safely bound theme inventory output, and keep unselected revision counts distinct from failed database measurements.
- Consolidate routine cleanup into a preview of disposable metadata, old rotated logs, generated development caches and expired DB transients. Add combinable `-db`, `-files`, `-logs` and `-development` selectors, `--execute` and bounded `--verbose` details. Explicit revision/target/backup/confirmation safeguards remain.
- Replace repeated zero-result paragraphs with a colored fleet table and measured totals. Treat unavailable providers and invalid responses as incomplete. Escape terminal controls in displayed labels and details.
- Add brief everyday help, `help all` and `help cleanup`, status area shortcuts, explicit cache blog/network selectors, and stdout-aware color controls. Ensure command help and invalid update arguments cannot start an update.
- Integrate the PR #9 and #8 cleanup snapshot, DB identity, multisite and LiteSpeed output protections.

### Cleanup preservation and snapshot refinement

- Safely bound and escape LiteSpeed provider responses, reject unsafe option-readback files, and distinguish output failures from command completion. Add 13 inert output/readback methods.

- Integrate the multisite table/cache scope safeguards with cleanup snapshot/evidence preservation.
- Bind native database mutations to the selected table plan and connected/configured database identity; refuse changes around backup or final execution even when table names match.
- Add inert race regressions and real disposable WordPress/MySQL identity mismatch coverage without changing public CLI syntax.

- Inspect complete eligible files for executable-like markers under bounded streaming limits; do not treat a benign prefix as clearance.
- Preserve IDE/project settings and named recovery/evidence directories; narrow development cleanup to generated caches.
- Confirm actual candidates before execution, reject changed snapshots and record backup/removal progress in private manifests.
- Add real-file and terminal regressions plus exact attribution/link/artwork preservation checks.

### Isolated database recovery validation

- Add an opt-in, GitHub-only database recovery integration drill using fresh loopback MySQL databases: native table-scoped cleanup backup recovery, whole-database backup round-trip, damaged-backup rejection and unrelated-data preservation.
- Add offline recovery-test boundary checks and document the difference between fixture recovery validation and testing an individual production backup. Do not add a production restore command or weaken existing mutation safeguards.
- Correct LiteSpeed credential documentation to describe the existing in-process bridge and the remaining environment/loaded-code exposure boundary.

## 0.1.1 — 2026-09-24

- Explicitly empty or invalid `sites` directory arguments now stop with exit 2 instead of falling back to fleet inventory.
- Directory targets retain exclusions relative to the original fleet root; discovery cache keys include that scope.
- Uninstall refuses update/recovery markers, including dangling symlinks, before changing managed files.
- Cleanup treats excluded nested installations as traversal boundaries, so a selected parent cannot clean an excluded child.

Add approved README artwork, distribution regressions, supported-PHP CI, pinned Actions and corrected project Codex defaults.

## 0.1.0 — initial Press family extraction

- Fix downloaded portable/user installation: validate the single-root archive, extract its contents without assuming validator output, and ignore inherited tar/gzip options. Add offline download-path, identity, archive/link and transport-failure regression tests.
- Independent wordpress maintenance, cleanup and performance management product extracted from pinned PressWarden 1.1.24.
- Preserved relevant feature implementation and regression fixtures.
- Isolated all operational namespaces, configuration, state and lifecycle paths.
- Added fail-closed target/mutation boundaries, private recovery information and product-specific reporting.
- See README for deliberate safety changes and unsupported capabilities; this snapshot is not a claim of production-host validation.
