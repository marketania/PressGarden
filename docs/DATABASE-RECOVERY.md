# Database backups and recovery validation

A checksum proves that a saved SQL file still matches its recorded bytes. It does not prove that it can be imported, that all required data was included, or that a recovered website works. PressGarden therefore continues to describe every ordinary backup as **checksum verified; restore not tested**. Passing the repository's recovery test does not change that statement about your individual backup.

## Backup scope matters

Native database operations normally back up the selected WordPress-registered tables. An explicit `--tables` selection can add owned tables within the selected prefix. A table-scoped backup is not a complete website/database backup when other required plugin tables are outside the selection.

The unscoped backup helper used by LiteSpeed database operations exports the configured database. That can include unrelated applications or other installations sharing the database. Treat such a dump as sensitive, and do not blindly import it over a live shared database. Revision deletion also uses an unscoped backup because WordPress deletion hooks can affect more than the selected table list.

SQL alone does not include uploads, plugin/theme code, `wp-config.php`, server configuration, external services or credentials held elsewhere. Nontransactional tables and concurrent writers may require a host-level snapshot or write quiescence for a consistent recovery point.

## Automated recovery drill

`tests/integration/database-restore.py` runs as a distinct step of the existing read-only GitHub CI workflow, against its disposable loopback MySQL service. It is **not an administrator-facing restore command**.

The test accepts no command-line arguments, site paths, database names, SQL files or remote connection settings. It requires `PRESSGARDEN_ALLOW_ISOLATED_RESTORE_TEST=1`, the PressGarden GitHub Actions context and the ephemeral service password. Product/WP-CLI configuration is isolated beneath a new private temporary workspace. Four randomly named databases are created by the test; two restore destinations start empty.

The drill exercises:

1. A native cleanup preview with a nondefault WordPress prefix, followed by actual cleanup through the public CLI. Preview must preserve the fixture rows; execution must create a private, checksummed backup before deleting the expired fixture transient.
2. A deliberately damaged backup copy. Verification must reject it before import, and the destination must remain empty.
3. Recovery of the two explicitly selected tables into an empty destination, including the deleted transient and exact serialized, UTF-8, binary and NULL fixture values. Unselected tables must not appear in that scoped restore.
4. A separate whole-database export through the same production helper used by LiteSpeed operations. Import into another empty destination must produce a canonical schema-and-data dump identical to the source snapshot. This includes an unrelated-prefix MyISAM sentinel table: inclusion is expected for a whole-database backup, not for the scoped backup.
5. Preservation of the source during recovery and of a separate unrelated WordPress fixture database throughout the drill. All created databases are then dropped only after identity/loopback checks; CI destroys the disposable service afterward.

Only status messages, versions, counts and assertion results are logged. The workflow does not upload SQL dumps, private configuration or database credentials as artifacts. Offline tests in `tests/recovery-drill.py` cover authorization, malformed/missing checksums, changed bytes, links, permissions, scope, unsafe targets and refusal to overwrite a nonempty destination.

For the full restore, canonical dump comparison normalizes only the redundant `CHARACTER SET utf8mb4` clause when a column already specifies a `utf8mb4_*` collation. MySQL defines that collation as selecting the same character set even without the explicit clause; import/re-export may print it explicitly. No row values, column types, defaults, engine choices or collations are excluded from comparison. The drill additionally compares effective column metadata from `information_schema.COLUMNS`, including character sets and collations, to detect real schema changes independently of dump formatting. Offline regressions prove that changed charsets, collations, types, defaults, engines and row values are not accepted as equivalent.

The workflow uses real WP-CLI database export/import commands and a real MySQL service, not database mocks. The scope and data assertions apply to these fixtures and the versions recorded in the run. They do not establish live HTTP behavior, external-service restoration, host-specific compatibility, concurrent-write consistency or a production recovery time objective.

## Before production maintenance

Identify the exact installation, database and table scope. Retain an off-host copy of all required database and file backups; review any shared-database contents. Record the application and database versions, backup time, maintenance window and recovery plan. Do not treat a successful checksum check or repository CI run as your own restore drill.

Restore a copy into a separately provisioned staging database with explicitly verified staging credentials. Review the SQL scope before import. Keep email, payment, webhook and other external side effects disabled in the isolated staging environment. Verify schema, representative data, administrator access, URLs, uploads, active plugins and application workflows there. Compare the result to the intended recovery point and document the findings before considering any in-place production recovery.

There is no new automatic production restore or rollback feature in this change. Never use this CI test against a client installation; it deliberately refuses user-supplied targets.

## Upstream command references

- [WP-CLI database export](https://developer.wordpress.org/cli/commands/db/export/): table selection and database dump options.
- [WP-CLI database import](https://developer.wordpress.org/cli/commands/db/import/): executes the supplied SQL against the configured database; it does not create the database itself.

- [MySQL column character sets and collations](https://dev.mysql.com/doc/mysql-g11n-excerpt/8.0/en/charset-column.html): an explicit collation selects its associated character set.
