# Changelog

## 0.1.1 — 2026-09-24

- Explicitly empty or invalid `sites` directory arguments now stop with exit 2 instead of falling back to fleet inventory.
- Directory targets retain exclusions relative to the original fleet root; discovery cache keys include that scope.
- Uninstall refuses update/recovery markers, including dangling symlinks, before changing managed files.
- Cleanup treats excluded nested installations as traversal boundaries, so a selected parent cannot clean an excluded child.

Add approved README artwork, distribution regressions, supported-PHP CI, pinned Actions and corrected project Codex defaults.

## Unreleased

- Add an opt-in, GitHub-only database recovery integration drill using fresh loopback MySQL databases: native table-scoped cleanup backup recovery, whole-database backup round-trip, damaged-backup rejection and unrelated-data preservation.
- Add offline recovery-test boundary checks and document the difference between fixture recovery validation and testing an individual production backup. Do not add a production restore command or weaken existing mutation safeguards.
- Correct LiteSpeed credential documentation to describe the existing in-process bridge and the remaining environment/loaded-code exposure boundary.

## 0.1.0 — initial Press family extraction

- Fix downloaded portable/user installation: validate the single-root archive, extract its contents without assuming validator output, and ignore inherited tar/gzip options. Add offline download-path, identity, archive/link and transport-failure regression tests.
- Independent wordpress maintenance, cleanup and performance management product extracted from pinned PressWarden 1.1.24.
- Preserved relevant feature implementation and regression fixtures.
- Isolated all operational namespaces, configuration, state and lifecycle paths.
- Added fail-closed target/mutation boundaries, private recovery information and product-specific reporting.
- See README for deliberate safety changes and unsupported capabilities; this snapshot is not a claim of production-host validation.
