# LiteSpeed Database Maintenance

PressGarden provides verified LiteSpeed Cache database maintenance for focused runs and for the write-capable `db` and `full` suites.

## Commands

Inspect the current LiteSpeed database-optimizer state without changing anything:

```bash
pressgarden litespeed-db status [target]
```

Run cleanup and verify the resulting state:

```bash
pressgarden litespeed-db optimize [target]
```

`target` follows normal PressGarden targeting: a website name, nested website name, directory, `all`, or the configured fleet when omitted. The focused command also accepts `--target SITE` / `--site SITE`.

For the umbrella LiteSpeed database interface, both of these are valid PressGarden forms:

```bash
pressgarden litespeed database optimize-all example.com
pressgarden litespeed database optimize-all --target example.com
```

Do not prefix a website itself with `--` (for example `--example.com`). PressGarden detects that common mistake and prints the corrected command instead of forwarding it to the lower-level parser.

## Fleet execution

Fleet maintenance is streaming. After one fleet confirmation, PressGarden preflights, measures, maintains, and verifies each discovered installation immediately before moving to the next one. It does not wait for an expensive whole-fleet preflight before the first database is changed.

Active-site preflight also probes the LiteSpeed database command family once instead of requesting help for every cleanup subcommand. This substantially reduces redundant WordPress bootstraps on large shared-host fleets while preserving per-site errors and final verification.

## What “verified” means

PressGarden does not consider a zero WP-CLI exit code sufficient proof that a site is optimized.

The state probe loads LiteSpeed Cache and reads `LiteSpeed\DB_Optm::db_count()` for the same categories used by `wp-admin/admin.php?page=litespeed-db_optm`:

- Post Revisions
- Orphaned Post Meta
- Auto Drafts
- Trashed Posts
- Spam Comments
- Trashed Comments
- Trackbacks/Pingbacks
- Expired Transients
- All Transients
- Optimize Tables

This preserves LiteSpeed's own revision-retention settings and counter semantics instead of approximating the dashboard with separate PressGarden SQL.

For every eligible installation, PressGarden prints `BEFORE`, runs maintenance, prints `AFTER`, and classifies the result:

- `ALREADY OPTIMIZED` — every LiteSpeed dashboard counter was already zero, so no cleanup command was run.
- `VERIFIED` — cleanup commands completed and every LiteSpeed dashboard counter is zero afterward.
- `UNVERIFIED` — commands completed, but one or more dashboard counters remain non-zero or the resulting state could not be read.
- `FAILED` — one or more required LiteSpeed commands failed.

Database size is shown before and after when available, but allocation size is telemetry only. MySQL can retain allocated space after rows are deleted, so size reduction is not used as the verification verdict.

## Commands PressGarden executes

For a single-site WordPress installation, PressGarden runs the documented command groups sequentially from the WordPress directory:

```bash
wp litespeed-database clear_posts
wp litespeed-database clear_comments
wp litespeed-database clear_trackbacks
wp litespeed-database clear_transients
wp litespeed-database optimize_tables
```

LiteSpeed's database command family does not accept ordinary WP-CLI global parameters. PressGarden therefore does not append `--path`, `--skip-plugins`, `--skip-themes`, `--skip-packages`, or `--no-color` to the real database-maintenance commands.

The state probe is different: it uses ordinary `wp eval-file` with LiteSpeed Cache loaded so it can read the plugin's own `DB_Optm` counters.

## Residual verification pass

After the first maintenance pass, PressGarden immediately re-reads the LiteSpeed counters. If any category remains non-zero, it performs one targeted residual pass for the command groups that still have work and reads the counters again.

This matters for cases where one cleanup operation exposes another cleanup opportunity. For example, deleting auto drafts or trashed posts can leave metadata that becomes orphaned after the first orphan-meta cleanup has already run.

PressGarden never loops indefinitely. After the residual pass, remaining non-zero counters produce `UNVERIFIED` rather than a false success.

## Multisite

Before changing a multisite installation, PressGarden obtains and validates all blog IDs. It measures every validated blog separately, aggregates the dashboard counters for the installation, and runs each maintenance command with the documented blog argument:

```bash
wp litespeed-database clear_posts blog ID
wp litespeed-database clear_comments blog ID
wp litespeed-database clear_trackbacks blog ID
wp litespeed-database clear_transients blog ID
wp litespeed-database optimize_tables blog ID
```

Malformed or incomplete blog inventory prevents cleanup from starting. A partial command failure is reported as `FAILED`; completed actions are not hidden.

## DB and FULL suite integration

`pressgarden db` and `pressgarden full` run verified LiteSpeed maintenance immediately before PressGarden's native SQL table maintenance:

```text
Database security scan
→ Database malware scan
→ LiteSpeed status BEFORE
→ LiteSpeed cleanup
→ LiteSpeed status AFTER / verification
→ Native table check / conditional repair / optimize
→ Native final verification
```

Sites without LiteSpeed Cache, or with the plugin inactive, are reported as unavailable/skipped and still continue to native database maintenance. A LiteSpeed failure makes the overall suite incomplete but does not prevent independent native maintenance from running on later steps.

Disable only the automatic suite step with:

```bash
```

The explicit `litespeed-db status` and `litespeed-db optimize` commands remain available.

## Fleet summary

The final report separates:

- optimized + verified installations;
- already optimized installations;
- LiteSpeed-unavailable installations;
- unverified installations;
- failed installations;
- measured aggregate database allocation before and after;
- actual counter reductions for revisions, orphaned metadata, drafts/trash, comments, trackbacks, transients, and tables requiring optimization.

`Expired Transients` is a subset of LiteSpeed's `All Transients` row count, so the two removal figures overlap and are not added together.

## Interruption safety

If maintenance is interrupted while commands are running, actions that already completed remain applied. PressGarden does not replay an interrupted `litespeed-db` step through `pressgarden continue`; run a fresh `db`, `full`, or focused `litespeed-db optimize` pass so current database state is re-measured first.

## Scheduled maintenance

A weekly maintenance cadence is a reasonable starting point for many managed sites. Example Sunday 3:00 AM focused cleanup:

```cron
0 3 * * 0 PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" PRESSGARDEN_INTERACTIVE=0 /path/to/pressgarden litespeed-db optimize all >> "$HOME/.local/state/pressgarden/litespeed-db-cron.log" 2>&1
```

To schedule the complete database security and maintenance workflow instead, substitute `pressgarden db all`. Confirm WP-CLI and the intended PHP binary are available in the cron environment before enabling fleet execution.
