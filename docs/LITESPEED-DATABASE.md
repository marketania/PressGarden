# LiteSpeed Database Maintenance

PressGarden provides explicit LiteSpeed Cache database maintenance. It does not have security scan suites, a `full` command, or automatic LiteSpeed cleanup inside native database checks.

## Choose the right interface

| Purpose | Command | Meaning |
|---|---|---|
| Measure LiteSpeed optimizer counters | `pressgarden litespeed-db status example.com` | Read the plugin's dashboard counters and allocation estimate |
| Clean and verify LiteSpeed counters | `pressgarden litespeed-db optimize example.com` | Back up, run cleanup groups, measure again, and report verified/unverified state |
| Inspect available LiteSpeed commands | `pressgarden litespeed database status --target example.com` | Availability preflight, not dashboard measurement |
| Invoke the upstream all-in-one action | `pressgarden litespeed database optimize-all --target example.com` | Back up and run `wp litespeed-database optimize_all`; command completion is not the focused workflow's all-counters-zero verification |
| Check native WordPress tables | `pressgarden db check example.com` | Independent read-only native CHECK, not LiteSpeed cleanup |

A target can be a website name, intended nested installation, directory, or explicit `all`. An omitted target uses the configured fleet. Both LiteSpeed interfaces accept `--target SITE` / `--site SITE`; database actions also accept a positional website when it is unambiguous. Explicit empty or unresolved targets never select the fleet. See [site targeting](SITE-TARGETS.md).

Do not prefix a website itself with `--`. Use `example.com` or `--target example.com`, not `--example.com`.

## Focused status and optimization

```bash
# Read current counters; no cleanup commands are run.
pressgarden litespeed-db status example.com

# Explicit mutation: confirmation, private SQL backup, cleanup, verification.
pressgarden litespeed-db optimize example.com
```

For fleet optimization, one confirmation authorizes the selected scope. The focused workflow preflights and processes each discovered installation before moving to the next; it does not wait for an expensive whole-fleet provider preflight. Missing/inactive LiteSpeed Cache is reported as unavailable/skipped, not installed or activated. WordPress/command failures remain errors.

Before cleanup of an eligible site, PressGarden requires a private SQL backup. Failure to export or validate that backup withholds cleanup for that site. LiteSpeed backups cover the configured database and can include other data when a database is shared. Protect the backup outside website roots and plan sufficient disk space. Checksum verification is not a restore test or a guarantee of cross-table consistency. See the [database operation safeguards](../README.md#database-operations).

## What verified means

The focused workflow loads LiteSpeed Cache and reads `LiteSpeed\DB_Optm::db_count()`, the source used by `wp-admin/admin.php?page=litespeed-db_optm`, for:

- Post revisions, orphaned post meta, auto drafts, and trashed posts.
- Spam comments, trashed comments, and trackbacks/pingbacks.
- Expired transients, all transient rows, and tables to optimize.

These retain LiteSpeed's own retention settings and counter semantics, rather than a separate approximation of the dashboard.

| Result | Meaning |
|---|---|
| ALREADY OPTIMIZED | Every measured dashboard counter was already zero; no cleanup command ran. |
| VERIFIED | Cleanup commands completed and all measured dashboard counters are zero afterward. |
| UNVERIFIED | Commands completed but counters remain nonzero, or resulting state could not be read. |
| FAILED | A required precondition or execution step failed. |

Nonzero counters can reflect regenerated transients or concurrent activity rather than a failed deletion command. PressGarden reports the observed state; it does not claim full optimization in that case. Successful command completion alone is not verification.

## Commands used by the focused workflow

For a single-site installation, the measured workflow uses these groups sequentially:

```bash
wp litespeed-database clear_posts
wp litespeed-database clear_comments
wp litespeed-database clear_trackbacks
wp litespeed-database clear_transients
wp litespeed-database optimize_tables
```

The database family is invoked inside the selected WordPress directory without standard WP-CLI global flags such as `--path` or `--skip-plugins`. The separate measurement probe uses ordinary `wp eval-file` with LiteSpeed loaded. WordPress/plugin code can run during these calls; this is not a sandbox for an infected website.

After the first pass, the workflow re-reads the counters. It makes **one bounded residual pass** through groups with remaining work and measures again. It never loops until transients disappear. Remaining nonzero/unreadable state results in UNVERIFIED and an incomplete exit code.

## Multisite scope

The focused `litespeed-db` workflow inventories and validates the network's blog IDs, measures them separately, aggregates counters, and runs the cleanup groups with `blog ID`. An incomplete inventory prevents cleanup. This is network scope within the selected WordPress installation, not a one-blog operation. The focused CLI does not accept a `--blog` selection.

The advanced interface can explicitly pass a blog operand:

```bash
pressgarden litespeed database optimize-all --blog=2 --target example.com
```

Select an existing blog deliberately. This advanced command is not the focused network-wide measurement/residual workflow. Omitting the blog operand leaves upstream default-blog behavior; it must not be interpreted as verified network-wide cleanup.

Native `db` operations have separate table/blog selection rules. Refer to the [README](../README.md#database-operations) rather than assuming native and LiteSpeed scope are identical.

## Native maintenance remains separate

```bash
pressgarden db status example.com
pressgarden db check example.com
pressgarden db repair example.com
pressgarden db optimize example.com
pressgarden db cleanup example.com
```

These are independent requests, not a recommended sequence to run indiscriminately. CHECK does not silently repair, optimize, or call LiteSpeed. Repair follows supported storage-engine semantics. Native cleanup is a preview unless `--execute` is supplied. No command above runs a malware scan. Avoid duplicate native optimization after LiteSpeed unless the observed table state justifies it.

## Output and exit codes

The focused summary separates checked/processed, optimized-and-verified, already optimized, unavailable, unverified, and failed installations. It reports measured before/after allocation pairs and **net counter decreases**, not guaranteed rows deleted by this process under concurrent writes.

Expired-transient timers are a subset of transient rows; the figures overlap and must not be added. Allocation estimates are telemetry, not guaranteed filesystem space reclaimed and not the basis of the verification verdict. Missing measurements remain unavailable.

`0` means the requested focused operation completed under its documented semantics, including a no-eligible-change result. `1` indicates declined confirmation. `2` indicates incomplete discovery, preconditions, execution, or verification. A fleet can have successful earlier sites and still return `2` for later failures.

## Interruption and scheduling

An interrupted mutation is not automatically rolled back: completed cleanup groups remain applied. Inspect output and retained backups before retrying. Start with a fresh focused status measurement, then deliberately request optimization again if warranted. PressGarden has no scan-continuation facility.

Example cron entry for a deliberately chosen Sunday 3:00 AM maintenance window:

```cron
0 3 * * 0 PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" PRESSGARDEN_INTERACTIVE=0 /path/to/pressgarden litespeed-db optimize all >> "$HOME/.local/state/pressgarden/litespeed-db-cron.log" 2>&1
```

Before installing a cron entry, verify the executable and WP-CLI/database clients, the intended configuration/fleet root, private writable log directory, backup space, and recovery procedure. The log's parent directory must already exist or shell redirection prevents the command from starting. Omitted or `all` targets are fleet-wide. Intentional automation does not disable backups, target isolation, or verification. Use `pressgarden db check all` for a separate native read-only scheduled check; there is no combined database-security-and-maintenance action.
