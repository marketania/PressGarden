# Cleanup preview, preservation and recovery

This refinement is limited to disposable filesystem cleanup. It does not replace
the separate multisite database/cache scope work in PR #8. No WordPress bootstrap,
network service, sibling tool, runtime AI, version bump or release is introduced.

## Safe first use

```bash
./pressgarden help
./pressgarden sites /absolute/path/to/staging-wordpress
./pressgarden cleanup preview /absolute/path/to/staging-wordpress
```

Preview does not delete or create recovery copies. Toolkit-owned state/discovery
caches may still be written. Execution shows the canonical site path and actual
candidate list before asking for confirmation on each site. The same in-memory
candidate snapshots are checked after approval; execution does not silently add
new candidates. `PRESSGARDEN_INTERACTIVE=0` remains deliberate authorization for
unattended execution, not a way around backup, scope or verification checks.

## What is preserved

Current logs, uploads/application content, linked or multiply linked files,
plugin/theme sources, VCS trees and unknown files remain outside routine cleanup.
Named `backup`, `backups`, `quarantine`, `evidence` and `wflogs` directories are now
explicit traversal boundaries. This name-based protection does not identify all
possible recovery storage: configure exclusions for differently named archives.

`--development` is narrowed to recognized generated caches. IDE directories
`.idea`/`.vscode` and authored root configuration such as `.editorconfig`,
`phpunit.xml`, lint rules and Git configuration are no longer disposable merely
because they are old. Recognized generated cache files and cache directories
still need the configured age and other eligibility checks. Live Git trees remain
protected. This is an intentional safety tightening, not a missing cleanup result.

## Content coverage and stale plans

Each eligible regular file is now streamed completely for the existing
executable-content heuristic and SHA256, rather than inspecting only its first
64 KiB. Overlapping blocks detect split markers. Maximums remain 64 MiB per file,
1,000 candidates, 200,000 directory entries and depth 24. Total candidate bytes
inspected are capped at 256 MiB per site; exceeding a budget refuses execution.
This is not malware clearance: compressed/encoded payloads are not decoded and
no signature engine is claimed. A review item stops that site's cleanup.

Before backups and removal, validate content digest plus device, inode, size,
mtime, ctime, mode, owner, group and link count. A changed candidate or newly
created nested WordPress installation refuses the stale plan. PHP stat caches
are cleared before path checks and descriptor metadata is compared after opens.
These checks reduce races but cannot provide an atomic filesystem snapshot or
coordinate arbitrary external writers. Stop other administrative writers first.

## Backup and interruption

All copies must verify before the first deletion. Private recovery metadata is
created before backup work, and records each verified copy. Immediately before
and after each unlink, progress is atomically published to the per-run manifest.
Where available, files are synchronized with `fsync`; PHP 7.4 still runs without
that function. This is not a promise of crash-proof storage or directory fsync.

`BACKUP_FAILED_NOT_DELETED` means this invocation did not begin deletion.
`PENDING_REMOVE`, `PARTIAL` or `UNVERIFIED_OR_UNCHANGED` needs inspection of both
the original path and its recovery copy. Never assume a pending file is present
or absent after interruption. `COMPLETED` requires the documented verifications.
Do not blindly restore over a newer file. Logical removed bytes are not net disk
space reclaimed because recovery copies remain. No automatic rollback is claimed.

## Evidence and limits

Baseline main `b1a78ece9e0cef83b2721ae5dc0464f164b0b165` passed 20 local scripts.
New tests reproduced late executable markers being deleted, authored settings
being selected and confirmation preceding preview. Internal stale-plan tests
add a new explicit snapshot contract rather than claiming an old public plan API.
The new suite uses real temporary files, backup collisions and an actual PTY
confirmation; no client sites or data are involved. Attribution tests protect the
original credits, link markup, provenance, license and approved logo.

Run `bash tests/run.sh` and consult exact-head PR CI for current evidence. This
checkpoint does not certify every host, database, provider, or recovery situation.
The broader refinement brief and unmerged PR #8 require separate acceptance.

## Primary sources and decisions

- [PHP clearstatcache](https://www.php.net/manual/en/function.clearstatcache.php): clear cached metadata when checking a changing path.
- [PHP fstat](https://www.php.net/manual/en/function.fstat.php): compare the opened descriptor with the expected file identity.
- [WordPress hardening](https://developer.wordpress.org/advanced-administration/security/hardening/): least privilege and independent backups, not universal security claims.
