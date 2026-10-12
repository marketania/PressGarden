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
