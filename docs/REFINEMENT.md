# Refinement checkpoint

Baseline: `b1a78ece9e0cef83b2721ae5dc0464f164b0b165` (0.1.1), verified against
GitHub tree `30c5c94608688d5b43ade3eddc7da633b7c46c66`. The complete baseline
local gate passed 20 scripts without syntax or test failures on PHP 8.4.23.

## Corrected scope defects

A primary multisite blog shares its prefix with network-global tables. The
native database scope validator previously accepted explicit `wp_users` and
`wp_blogs` selections even in per-blog mode. It now rejects tables returned by
WordPress's `wpdb::tables('global', true)` API, including custom user mappings.
Per-blog registered tables and owned plugin tables remain eligible. A single
site retains its registered user tables. This is a scope guard, not permission
to operate on other installations sharing a database.

The convenience `cache clear` command previously routed to LiteSpeed's
network-wide `purge all` with no explicit network selection. The same upstream
operation through the advanced interface had this ambiguity. Multisite all-purge
now requires `--network`; a blog purge verifies a positive, existing, active ID
inside the selected network. The read-only scope marker is checked again after
taking the existing writer lock. Failed/changed scope stops before a purge.
Single-site behavior and all existing SQL backup/destructive opt-ins remain.

## Tests and limits

`tests/database-scope.php` uses an inert database inventory adapter to cover
primary/secondary/custom global mappings, single-site behavior and foreign
prefixes. `tests/purge-scope.py` executes the real CLI and the new PHP scope
helper against temporary layouts and a recording provider adapter. It verifies
single-site success, explicit network authorization, per-blog membership,
failed/changed scope and invalid arguments. No real cache is flushed by these
local tests. Attribution tests retain original text/links and full hashes of
LICENSE, PROVENANCE and the approved artwork.

The isolated WordPress CI fixture additionally converts its freshly generated
site to multisite, exercises real WordPress table membership and scope APIs,
and checks convenience-purge refusal. It does not issue a whole-network purge.
Consult PR CI for actual execution results; a test definition alone is not proof
it ran. Existing backup/restore-drill coverage remains intact.

Run `bash tests/run.sh` for the local gate. A purge return code is not an
independent HTTP cache measurement. Scope checks execute trusted WordPress
bootstrap code, including MU-plugins; skip flags are not a sandbox. Existing
per-product locks do not coordinate all other tools or external writers.
Database snapshots, engine-specific backup consistency, custom layouts and
credentialed services require deployment-specific validation. This focused
checkpoint does not claim every command and environment in the full refinement
brief is certified. No versions/tags/releases or production sites are changed.

## Official guidance and decisions

- [LiteSpeed WP-CLI](https://docs.litespeedtech.com/lscache/lscwp/cli/): `litespeed-purge all` purges every network site; use `blog` for explicit blog scope. Keep database commands free of unsupported WP-CLI global flags.
- [WordPress table scopes](https://developer.wordpress.org/reference/classes/wpdb/tables/): use actual global mappings rather than a prefix-only guess.
- [WP-CLI object-cache flush](https://developer.wordpress.org/cli/commands/cache/flush/): persistent cache flushing can affect all multisite blogs. No generic object-cache flush is added.
- [Multisite fixture conversion](https://developer.wordpress.org/cli/commands/core/multisite-convert/): use only fresh disposable CI sites.
- [OpenSSF Scorecard](https://scorecard.dev/): retain reviewable dependency updates and pinned CI actions. No Scorecard score or certification is claimed.


## Native database identity continuation

A table list is not a database identity. The combined candidate now fingerprints
`DB_NAME`, `DB_HOST`, `DB_USER`, the connected `DATABASE()`, server `@@hostname`
and `@@port`, and the selected WordPress prefix. The connected database name must
match the configured export database. Only the SHA256 fingerprint is passed
between processes; the fingerprint itself does not disclose names, users or
passwords. WordPress bootstrap and other reporting retain their documented trust boundaries. Unavailable identity information stops a native mutation, not ordinary
read-only status/check operations.

For native repair, optimize and executing cleanup, the fingerprint is captured
with the preflight plan, checked under the site writer lock before the SQL export,
checked after the export, and checked with the exact table list in the final PHP
process before maintenance SQL. This prevents a stable connection/database switch
from silently reusing an approved same-table plan or an unrelated backup. The
internal helper refuses mutation calls lacking both identity and table-plan gates.
Public command syntax and backup requirements are unchanged.

A mismatch means **no native maintenance SQL is issued for that refused site**;
earlier sites in a batch may already have completed, and bootstrap has its own effects. A private
SQL export may already exist; retain it and investigate the configuration or routing
change before creating a fresh plan. Do not bypass the check by manually supplying
a new hash or blindly retrying a mutation. Restore procedures still require a
separate verified recovery decision.

These are bounded change-detection checks, **not database-server authentication,
a distributed lock, or an atomic configuration/backup transaction**. Trusted
WordPress bootstrap, `db.php` routing/drop-ins, proxies, failover and export-client
configuration remain environment-specific trust boundaries. The same host/name/
port can refer to a changed physical server; temporary switches between probes,
external writes and provider-managed routing cannot be ruled out by this hash.
A routing change can also trigger a conservative refusal. Stop competing admin
operations and validate the actual export/restore path in staging. Advanced
LiteSpeed provider operations retain their own existing safeguards and are not
claimed to implement this native fingerprint contract.

The new nine-method suite uses real wrapper subprocesses with recording tools and
PHP adapters to reproduce changed identity before/during/after export, missing
identity, backup failure, final-process mismatch and stable success. The live
fixture additionally compares two freshly created databases with identical table
names and refuses a cross-database fingerprint before removing an expired transient.
That real-server check is run by GitHub CI, not the local recording adapters.

Primary references:
- [MySQL information functions](https://dev.mysql.com/doc/refman/8.0/en/information-functions.html): `DATABASE()` is the current connection's selected database.
- [MySQL server variables](https://dev.mysql.com/doc/refman/8.0/en/server-system-variables.html): `hostname` and `port` describe the connected server, not a globally unique server identity.
- [MariaDB DATABASE](https://mariadb.com/docs/server/reference/sql-functions/secondary-functions/information-functions/database): equivalent current-database semantics; compatibility does not substitute for a real MariaDB integration run.

No main-branch merge, version bump, release, tag or production operation is included.
