# PressGarden

Fleet-scale **WordPress maintenance, cleanup and performance management** from the shell.

Owns routine maintenance, not malware remediation, vulnerability feeds, incident handling or quarantine. It does not install or automatically activate caching plugins.

PressGarden is a standalone MIT-licensed Linux/Bash/PHP application. It contains its own discovery, targeting, lifecycle and relevant operation code. Neither sibling repository is required. It is not a wrapper around PressWarden.

## Install this distribution

Requirements: Linux, Bash 4+, PHP CLI 7.4+, coreutils/find/tar; WP-CLI and its database clients for WordPress/database operations. Some operations need `flock`. Use only the installer published in this tool’s own repository. For a reviewed release, `curl -fsSLo install.sh https://raw.githubusercontent.com/marketania/PressGarden/main/install.sh` followed by `bash install.sh` installs this tool alone.

From this extracted tree:

```bash
PRESSGARDEN_INSTALL_SOURCE="$PWD" \
PRESSGARDEN_INSTALL_PREFIX="$HOME/tools/PressGarden" \
bash ./install.sh
```

Remote installer example above replaces only your downloaded installer file; do not run it from an existing source tree when reviewing that tree.

For a user-wide symlink, set `PRESSGARDEN_INSTALL_MODE=user` instead of a portable prefix. Existing installation destinations are refused; use their `update` command. The independent installer validates archive paths, identity and syntax; it never downloads the sibling tools.

## Commands

```bash
./pressgarden status example.com
./pressgarden db status example.com
./pressgarden db check example.com
./pressgarden db optimize example.com
./pressgarden db repair example.com
./pressgarden db cleanup example.com
./pressgarden db cleanup example.com --execute
./pressgarden db cleanup example.com --execute --revisions --older-than=60
./pressgarden cleanup preview example.com
./pressgarden cleanup execute example.com --logs --older-than=60
./pressgarden cache status example.com
./pressgarden cache clear example.com
./pressgarden litespeed-db status example.com
./pressgarden litespeed-db optimize example.com
./pressgarden litespeed option all --target example.com
./pressgarden sites
./pressgarden doctor example.com
./pressgarden config
./pressgarden help
./pressgarden --version
```

Use `example.com`, `example.com/shop`, an absolute directory, or explicit `all`. A named parent includes intended discovered nested installations. Exclusions are preserved after narrowing. Omitted targets use the configured fleet; **unknown, empty, excluded or ambiguous targets do not fall back to all**. Always inspect `sites` before fleet mutations.

## State and configuration

Portable: `config/config`, `var/`, `var/cache/`, `var/reports/` beneath this product's installation. User-wide: `$XDG_CONFIG_HOME/pressgarden/config`, `$XDG_STATE_HOME/pressgarden/`, `$XDG_CACHE_HOME/pressgarden/` with standard home-directory fallbacks. Override with `PRESSGARDEN_CONFIG_FILE`, `PRESSGARDEN_STATE_DIR`, `PRESSGARDEN_CACHE_DIR`, `PRESSGARDEN_REPORTS_DIR`. State/backups must be outside selected WordPress roots. No `PRESSWARDEN_*` compatibility variables are consumed by the new product.

Configuration is trusted shell input. Keep it administrator-owned and mode 600. Discovery and interaction options are in `config/config.example`; only product-relevant settings are included. Backups are never automatically pruned.

## Database operations

`db status` inventories selected table engines and allocation estimates. `db check` is read-only and never triggers repair/optimization. `db optimize` checks a table, runs OPTIMIZE only on a successful check, then verifies CHECK again. `db repair` skips healthy tables; only MyISAM/ARCHIVE/CSV repair is supported. Unsupported storage-engine CHECK/REPAIR responses are not classified as corruption. InnoDB repair is **not** invented via ALTER/recreate.

By default, native operations address WordPress-registered tables, not every table sharing the database. Explicit additional tables can be selected with `--tables=wp_example,wp_other` only within the selected installation's prefix. Multisite requires `--blog=ID`; native per-blog operations exclude network/global tables. A changed table plan aborts rather than broadening scope.

Every native repair/optimize/cleanup execution and advanced LiteSpeed DB mutation requires a private SQL export before writes. Exports have checksums; this is **not a restore test or a guarantee of a transactionally consistent MyISAM backup**. The native dump is table-scoped. LiteSpeed's dump covers the configured database, including all network tables, because the provider can operate across the network; it can contain other data in a shared database. Protect it and obtain a host snapshot before high-risk maintenance. SQL exports require sufficient filesystem space and the WP-CLI database client dependencies.

`db cleanup` is a preview unless `--execute` is specified. Expired transients are the default; revision removal additionally requires `--revisions`, with a default minimum age of 30 days and a maximum 1,000 deletions per invocation. API deletion counts and SQL affected-row counts are separate from net observed counter decreases.

`litespeed-db optimize` preserves the verified provider workflow: BEFORE counters from `LiteSpeed\DB_Optm::db_count()`, documented cleanup groups, AFTER counters, one bounded residual pass. Nonzero/unreadable counters do not produce a verified-optimized claim. The old internal security-suite flag can no longer authorize maintenance.

## LiteSpeed and cache providers

The `litespeed` advanced interface retains all eight migrated families: `option`, `purge`, `presets`, `image`, `online`, `debug`, `crawler`, `database`. Read the CLI help for the full commands. Operands use `--target SITE` where a positional target would be ambiguous.

| Family | Operation category |
|---|---|
| Options/presets | Performance configuration; private option backup before changes |
| Purge/crawler | Cache maintenance; confirmations for mutation |
| Image | Performance/external optimization; original-backup deletion is irreversible |
| Online/CDN | External service/account/DNS-related management; only explicitly invoked |
| Debug send | External support-data upload; separate privacy opt-in for automation |
| Database | Destructive cleanup/table maintenance; SQL backup required |

`cache status|clear|enable|disable` is a provider adapter for **LiteSpeed only**. Missing/inactive providers are reported, not silently installed or activated. Status/enable do not prove a cache HIT or working Redis connection. `option set` independently reads the value back; a mismatch is UNVERIFIED. Other advanced provider operations report **COMMAND COMPLETED**, not an invented effect/metric.

Sensitive option output is redacted; account/CDN mutation responses are withheld. Keys may be supplied as environment-variable references instead of literal CLI arguments, but the provider may receive them as subprocess arguments: this prevents shell-history disclosure, **not process-list disclosure**. Option exports contain secrets and are private. Existing export files and webroot destinations are refused.

In intentional automation, permanent image-backup removal also requires `PRESSGARDEN_LITESPEED_DESTRUCTIVE=1`; support report upload requires `PRESSGARDEN_LITESPEED_EXTERNAL=1`. These are not enabled by default. Database-family calls still execute inside the WordPress directory without standard WP-CLI global flags, as required by LiteSpeed.

## Conservative filesystem cleanup

`cleanup status|preview` never deletes. `cleanup execute` backs up every candidate and verifies copies before removal. Default candidates are old filesystem metadata such as `.DS_Store`, `Thumbs.db`, AppleDouble files and `.LSOverride`; optional `--development` includes recognized generated/development metadata, and `--logs` includes **old rotated logs only**. Current `debug.log`, `error_log`, application code, plugin/theme source trees, VCS directories, hardlinks and symlinks are not cleanup targets. Empty generated directories may remain.

Scans are bounded at 200,000 entries, 24 levels, 1,000 candidates, and 64 MiB per file. Executable-like content in a candidate stops deletion for that installation. This heuristic is not malware clearance; run PressWarden for a suspected compromise. Cleanup backups use an indexed manifest under `state/backups/file-cleanup/`; do not blindly restore over changed files. Removed logical file bytes are **not net disk space reclaimed**, since recovery copies are retained.

## Safety and automation

Mutations confirm on a terminal by default. `PRESSGARDEN_INTERACTIVE=0` is an explicit authorization for unattended operations—not a recommendation to apply changes fleet-wide. Backups, scope checks and verification are not bypassed. A failed site does not become a successful fleet; partial failures are reported.

WP-CLI operations run as the current account. Plugin skip flags do not suppress MU-plugins; loading WordPress is not a sandbox. Do not run maintenance/policy changes as incident remediation. Preserve evidence and investigate a suspected compromise first. Stop other administrative processes before updates or mutations; private state/operation locks are product-specific, not a cross-product distributed lock.

## Exit codes

`0`: requested operation completed under its documented semantics (or no eligible change). `1`: declined operation, review/partial work, or PHP configuration awaiting web verification as applicable. `2+`: invalid request, incomplete discovery/verification, dependency or execution failure. Provider COMMAND COMPLETED means command success, not independently measured service effectiveness. Status findings and unsupported capabilities are labeled explicitly.

## Update and uninstall

`./pressgarden update` targets `marketania/PressGarden`, never a sibling and never threat feeds. For isolated validation or recovery, test/update with a local validated distribution archive:

```bash
PRESSGARDEN_UPDATE_ARCHIVE=/absolute/path/PressGarden.tar.gz ./pressgarden update
```

The updater preserves private configuration and state; a sibling archive fails identity validation. See [update and recovery details](docs/UPDATING.md). `./uninstall.sh` confirms removal of managed program files only. It preserves saved config, backups and state. `--yes` is the explicit noninteractive alternative; it does not purge private data.

## Development and provenance

Run `bash tests/run.sh`. Tests use bounded temporary fixtures and mock external commands. Live fixture integration, when provided, must use an explicitly isolated test database; no production websites are used.

Separated from PressWarden 1.1.24 at `63adec182b4d3a20dbd5e24daa9b9fa0e98510b8`. See [provenance](PROVENANCE.md), [migration mapping](docs/MIGRATION.md), and [MIT license](LICENSE). PressWarden remains the security investigation tool; PressHarden manages security configuration and hardening. Siblings are optional alternatives for other responsibilities, not dependencies.
