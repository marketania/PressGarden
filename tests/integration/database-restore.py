#!/usr/bin/env python3
"""GitHub-only disposable MySQL recovery drill; NOT a production restore tool.

No site, database, SQL file, connection host or command arguments are accepted.
All databases and dumps are generated within this invocation. Runtime maintenance
continues to say "restore not tested" for each operator's individual backup.
"""
from __future__ import annotations

import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Mapping, Sequence


class DrillError(RuntimeError):
    """A failed assertion or refused operation; never implies recovery success."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise DrillError(message)


def canonical_dump(data: bytes) -> bytes:
    """Normalize only redundant utf8mb4 column charset spelling, never values.

    MySQL's COLLATE utf8mb4_* already selects the utf8mb4 character set.
    Re-export after import may additionally spell CHARACTER SET utf8mb4.
    Effective column metadata is also compared independently in the live drill.
    """
    lines = []
    in_create = False
    pattern = rb"^(  `[A-Za-z0-9_]+` (?:var)?char\([0-9]+\)|  `[A-Za-z0-9_]+` (?:tiny|medium|long)?text) CHARACTER SET utf8mb4(?= COLLATE utf8mb4_[A-Za-z0-9_]+(?: |,|\r?$))"
    for line in data.splitlines(keepends=True):
        if line.startswith(b"CREATE TABLE `"):
            in_create = True
        elif line.startswith(b") "):
            in_create = False
        if in_create:
            line = re.sub(pattern, rb"\1", line)
        lines.append(line)
    return b"".join(lines)


def same_dump(expected: bytes, actual: bytes, label: str) -> None:
    """Keep strict equality; diagnose changed statement classes without row data."""
    if expected == actual:
        return
    left, right = expected.splitlines(), actual.splitlines()
    print(f"DUMP MISMATCH {label}: expected {len(expected)} bytes/{len(left)} lines; "
          f"actual {len(actual)} bytes/{len(right)} lines", file=sys.stderr)
    changes = 0
    for kind, a, b, c, d in difflib.SequenceMatcher(None, left, right, autojunk=False).get_opcodes():
        if kind == "equal":
            continue
        changes += 1
        print(f"  {kind}: expected lines {a + 1}-{b}; actual lines {c + 1}-{d}", file=sys.stderr)
        for side, lines in (("expected", left[a:b]), ("actual", right[c:d])):
            for line in lines[:3]:
                table = re.match(rb"INSERT INTO `([A-Za-z0-9_]+)`", line)
                if table:
                    description = "INSERT " + table.group(1).decode() + " [row values withheld]"
                elif line.startswith((b"CREATE TABLE", b") ENGINE=", b"/*!", b"SET ")):
                    description = line[:240].decode("utf-8", "replace")
                else:
                    description = "[statement text withheld]"
                print(f"    {side}: {description}; bytes={len(line)}; "
                      f"sha256={hashlib.sha256(line).hexdigest()}", file=sys.stderr)
        if changes >= 4:
            break
    raise DrillError(label)


def authorize(arguments: Sequence[str], env: Mapping[str, str]) -> None:
    require(not arguments, "This test accepts no arguments or user-supplied targets.")
    require(env.get("PRESSGARDEN_ALLOW_ISOLATED_RESTORE_TEST") == "1",
            "Explicit isolated-restore-test opt-in is required.")
    require(env.get("GITHUB_ACTIONS") == "true" and
            env.get("GITHUB_REPOSITORY") == "marketania/PressGarden",
            "Run only in the PressGarden disposable GitHub CI job.")
    require(bool(env.get("PRESS_TEST_DB_PASSWORD")), "Ephemeral CI database password is required.")


def private_file(path: Path, root: Path) -> bytes:
    require(path.is_absolute() and root.is_absolute(), "Absolute fixture paths required.")
    require(path.is_relative_to(root), "Backup path is outside this fixture workspace.")
    require(path.resolve() == path, "Noncanonical or linked backup paths are refused.")
    for parent in (path, *path.parents):
        require(not parent.is_symlink(), "Linked backup paths are refused.")
        if parent == root:
            break
    try:
        info = path.lstat()
    except OSError as exc:
        raise DrillError("Required private backup file is missing.") from exc
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "Backup must be a single-link regular file.")
    require(stat.S_IMODE(info.st_mode) & 0o077 == 0, "Backup is not private to the fixture owner.")
    require(0 < info.st_size <= 64 * 1024 * 1024, "Fixture backup is empty or exceeds the test limit.")
    return path.read_bytes()


def verify_backup(path: Path, root: Path) -> None:
    require(path.name == "database.sql", "Unexpected backup filename.")
    data = private_file(path, root)
    record = private_file(path.with_name("database.sql.sha256"), root)
    match = re.fullmatch(rb"([0-9a-f]{64})  database\.sql\n?", record)
    require(match is not None, "Checksum record is malformed or names another file.")
    require(hashlib.sha256(data).hexdigest().encode() == match.group(1), "Backup checksum mismatch.")
    # Inputs are our own fresh dumps, not arbitrary operator-supplied SQL.
    require(not re.search(rb"(?im)^\s*(?:USE\s|CREATE\s+DATABASE\b|DROP\s+DATABASE\b)", data),
            "Dump contains a database-switching statement; restore refused.")


def validate_target(root: Path, path: Path, expected: str, observed: Mapping[str, str]) -> None:
    require(path.is_absolute() and path.is_relative_to(root), "Target is outside the generated workspace.")
    require(path.resolve() == path and not path.is_symlink(), "Linked target is refused.")
    require(re.fullmatch(r"pgrestore_ci_[0-9a-f]{24}_(source|scoped|whole|other)", expected) is not None,
            "Database is not a generated recovery fixture.")
    require(observed.get("DB_NAME") == expected and observed.get("DB_HOST") == "127.0.0.1:3306",
            "Database identity or loopback endpoint changed; operation refused.")


class Drill:
    def __init__(self, root: Path, password: str) -> None:
        self.root = root.resolve()
        self.repo = Path(__file__).resolve().parents[2]
        self.password = password
        self.wp = shutil.which("wp")
        require(self.wp is not None, "WP-CLI is required in the disposable runner.")
        self.tag = "pgrestore_ci_" + secrets.token_hex(12)
        self.sites: dict[Path, str] = {}
        self.created: list[Path] = []
        for name in ("home", "tmp", "state", "cache"):
            (self.root / name).mkdir(mode=0o700)
        config = self.root / "wp-cli.yml"
        config.write_text("{}\n")
        # Do not inherit product variables, WP-CLI packages, site config or API keys.
        self.env = {
            "PATH": os.environ["PATH"], "HOME": str(self.root / "home"),
            "TMPDIR": str(self.root / "tmp"), "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "WP_CLI_CONFIG_PATH": str(config), "WP_CLI_PACKAGES_DIR": str(self.root / "packages"),
            "WP_CLI_CACHE_DIR": str(self.root / "wp-cache"),
            "PRESSGARDEN_DIR": str(self.repo), "PRESSGARDEN_CONFIG_FILE": str(self.root / "no-config"),
            "PRESSGARDEN_SCAN_ROOT": str(self.root / "fleet"),
            "PRESSGARDEN_STATE_DIR": str(self.root / "state"),
            "PRESSGARDEN_CACHE_DIR": str(self.root / "cache"),
            "PRESSGARDEN_INTERACTIVE": "0", "PRESSGARDEN_PROGRESS": "0", "PRESSGARDEN_NOCOLOR": "1",
        }

    def run(self, args: Sequence[str], label: str, env: Mapping[str, str] | None = None) -> bytes:
        try:
            result = subprocess.run(list(args), cwd=self.root, env=dict(env or self.env),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
        except (OSError, subprocess.TimeoutExpired) as exc:
            # Do not include a command representation containing fixture credentials.
            raise DrillError(label + ": execution unavailable or timed out.") from exc
        if result.returncode:
            detail = result.stderr.decode("utf-8", "replace").replace(self.password, "[REDACTED]")[-1200:]
            raise DrillError(f"{label}: exit {result.returncode}. {detail}")
        return result.stdout

    def wp_run(self, site: Path, args: Sequence[str], label: str) -> bytes:
        return self.run([self.wp, f"--path={site}", "--skip-plugins", "--skip-themes", "--skip-packages",
                         "--no-color", *args], label)

    def guard(self, site: Path) -> None:
        require(site in self.sites, "Target was not created by this invocation.")
        values = {}
        try:
            for key in ("DB_NAME", "DB_HOST"):
                values[key] = json.loads(self.wp_run(site, ["config", "get", key, "--format=json"], "check fixture identity"))
        except (ValueError, TypeError) as exc:
            raise DrillError("Fixture identity could not be read.") from exc
        validate_target(self.root, site, self.sites[site], values)

    def make_site(self, role: str, installed: bool) -> Path:
        require(role in ("source", "scoped", "whole", "other"), "Unknown fixture role.")
        parent = "fleet" if installed else "recovery"
        site = self.root / parent / f"{role}.example" / "public_html"
        shutil.copytree(self.root / "core", site)
        db = f"{self.tag}_{role}"
        self.wp_run(site, ["config", "create", f"--dbname={db}", "--dbuser=root",
                          f"--dbpass={self.password}", "--dbhost=127.0.0.1:3306", "--dbprefix=pgcase_",
                          "--skip-check", "--quiet"], "create fixture-only configuration")
        self.sites[site] = db
        self.guard(site)
        self.wp_run(site, ["db", "create", "--quiet"], "create uniquely named fixture database")
        self.created.append(site)  # Only databases successfully created here can be dropped.
        if installed:
            self.wp_run(site, ["core", "install", f"--url=http://{role}.example.invalid",
                              "--title=Disposable recovery fixture", "--admin_user=fixture_admin",
                              "--admin_password=Disposable-only-password-7319", "--admin_email=fixture@example.invalid",
                              "--skip-email", "--quiet"], "install isolated WordPress")
        return site

    def query(self, site: Path, sql: str) -> bytes:
        self.guard(site)
        return self.wp_run(site, ["db", "query", sql, "--skip-column-names", "--batch", "--raw"], "fixture SQL")

    def tables(self, site: Path) -> list[str]:
        return sorted(self.query(site, "SHOW TABLES").decode().split())

    def snapshot(self, site: Path, name: str) -> bytes:
        self.guard(site)
        path = self.root / name
        self.wp_run(site, ["db", "export", str(path), "--single-transaction", "--skip-comments",
                          "--skip-dump-date", "--order-by-primary", "--hex-blob", "--compact"], "canonical fixture snapshot")
        return canonical_dump(path.read_bytes())

    def column_metadata(self, site: Path) -> bytes:
        # Read effective schema rather than trusting equivalent DDL spellings.
        rows = self.query(site, "SELECT TABLE_NAME,ORDINAL_POSITION,COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,"
                          "IF(COLUMN_DEFAULT IS NULL,'NULL',CONCAT('HEX:',HEX(COLUMN_DEFAULT))),"
                          "IFNULL(CHARACTER_SET_NAME,''),IFNULL(COLLATION_NAME,''),EXTRA,COLUMN_KEY,"
                          "HEX(GENERATION_EXPRESSION) FROM information_schema.COLUMNS "
                          "WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME,ORDINAL_POSITION")
        require(bool(rows.strip()), "Effective column metadata is empty or unavailable.")
        return rows

    def only_backup(self, state: Path) -> Path:
        files = list(state.rglob("database.sql"))
        require(len(files) == 1, "Expected one new backup for exactly one selected site.")
        verify_backup(files[0], self.root)
        return files[0]

    def restore(self, backup: Path, destination: Path) -> None:
        verify_backup(backup, self.root)  # Refuse damaged SQL before any import call.
        require(destination in self.sites and self.sites[destination].endswith(("_scoped", "_whole")),
                "Restore destination must be a generated recovery database, never a source.")
        self.guard(destination)
        require(not self.tables(destination), "Restore destination is not empty; overwrite refused.")
        self.wp_run(destination, ["db", "import", str(backup), "--skip-optimization"], "restore into empty fixture database")
        verify_backup(backup, self.root)

    def exercise(self) -> None:
        self.run([self.wp, "core", "download", f"--path={self.root / 'core'}", "--quiet"], "download clean WordPress fixture")
        source = self.make_site("source", True)
        other = self.make_site("other", True)
        scoped = self.make_site("scoped", False)
        whole = self.make_site("whole", False)
        print("Environment: WordPress " + self.wp_run(source, ["core", "version"], "WordPress version").decode().strip())
        print("Database: " + self.query(source, "SELECT VERSION()").decode().strip())
        unrelated = self.snapshot(other, "other-before.sql")
        text = "Recovery / اختبار الاستعادة / 🌱 / 'quotes' \\\n".encode().hex()
        self.query(source, "CREATE TABLE pgcase_payload (id INT PRIMARY KEY, payload LONGBLOB, note TEXT) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
                   "INSERT INTO pgcase_payload VALUES (1,0x0001090A0D275C22FF,'binary'),(2,NULL,'null'),"
                   f"(3,0x{ text },CONVERT(0x{text} USING utf8mb4));"
                   "CREATE TABLE outside_owner (id INT PRIMARY KEY, note VARCHAR(50)) ENGINE=MyISAM;"
                   "INSERT INTO outside_owner VALUES (1,'unrelated shared-database sentinel');"
                   "INSERT INTO pgcase_options (option_name,option_value,autoload) VALUES "
                   f"('pg_recovery_text',CONVERT(0x{text} USING utf8mb4),'no'),"
                   "('pg_recovery_serialized','a:1:{s:4:\"note\";s:7:\"restore\";}','no'),"
                   "('_transient_pg_recovery','expired-value-to-recover','no'),"
                   "('_transient_timeout_pg_recovery','100','no'),"
                   "('_transient_pg_current','keep-live-transient','no'),"
                   "('_transient_timeout_pg_current','4102444800','no');")
        options_sql = ("SELECT option_name,HEX(option_value),autoload FROM pgcase_options WHERE "
                       "option_name IN ('pg_recovery_text','pg_recovery_serialized','_transient_pg_recovery',"
                       "'_transient_timeout_pg_recovery','_transient_pg_current','_transient_timeout_pg_current') "
                       "ORDER BY option_name")
        payload_sql = "SELECT id,IFNULL(HEX(payload),'NULL'),HEX(note) FROM pgcase_payload ORDER BY id"
        expected_options, expected_payload = self.query(source, options_sql), self.query(source, payload_sql)
        outside = self.query(source, "SELECT * FROM outside_owner")
        command = ["bash", str(self.repo / "pressgarden"), "db", "cleanup", "source.example",
                   "--tables=pgcase_options,pgcase_payload"]
        self.run(command, "native cleanup preview")
        require(self.query(source, options_sql) == expected_options, "Preview changed fixture rows.")
        require(not list((self.root / "state").rglob("database.sql")), "Preview unexpectedly created a SQL backup.")
        self.run([*command, "--execute"], "native cleanup with mandatory backup")
        require(self.query(source, "SELECT COUNT(*) FROM pgcase_options WHERE option_name IN "
                           "('_transient_pg_recovery','_transient_timeout_pg_recovery')").strip() == b"0",
                "Expired fixture transient was not removed.")
        remaining_options = b"\n".join(line for line in expected_options.splitlines()
                                       if line.split(b"\t", 1)[0] not in
                                       (b"_transient_pg_recovery", b"_transient_timeout_pg_recovery")) + b"\n"
        require(self.query(source, options_sql) == remaining_options,
                "Cleanup removed or changed unexpired/nontransient fixture values.")
        backup = self.only_backup(self.root / "state")
        bad_dir = self.root / "damaged"
        bad_dir.mkdir(mode=0o700)
        bad = bad_dir / "database.sql"
        shutil.copy2(backup, bad)
        shutil.copy2(backup.with_name("database.sql.sha256"), bad.with_name("database.sql.sha256"))
        with bad.open("ab") as handle:
            handle.write(b"\n-- deliberately damaged fixture copy\n")
        try:
            self.restore(bad, scoped)
        except DrillError as exc:
            require(str(exc) == "Backup checksum mismatch.", "Damaged-backup rejection had an unexpected cause.")
        else:
            raise DrillError("Damaged backup was accepted.")
        require(not self.tables(scoped), "Damaged backup changed the restore destination.")
        self.restore(backup, scoped)
        require(self.tables(scoped) == ["pgcase_options", "pgcase_payload"], "Scoped restore included unrelated tables.")
        require(self.query(scoped, options_sql) == expected_options, "Restored option values differ from pre-cleanup fixture values.")
        require(self.query(scoped, payload_sql) == expected_payload, "Binary, NULL or UTF-8 values did not round-trip.")
        require(self.query(source, "SELECT * FROM outside_owner") == outside, "Native cleanup modified the unrelated table.")
        print("PASS: preview preservation; damaged backup rejected before import; 2 scoped tables restored.")
        print("PASS: deleted transient recovered; serialized/UTF-8/binary/NULL fixture values preserved.")

        before_whole = self.snapshot(source, "source-before-whole.sql")
        before_columns = self.column_metadata(source)
        whole_env = dict(self.env, PRESSGARDEN_STATE_DIR=str(self.root / "whole-state"), ROOT=str(source))
        # The same unscoped production backup helper used by LiteSpeed database operations.
        self.run(["bash", "-c", 'set -uo pipefail; . "$PRESSGARDEN_DIR/lib/_lib.sh"; '
                  '. "$PRESSGARDEN_DIR/lib/database-backup.sh"; pg_database_backup "$1"',
                  "pressgarden-disposable-recovery", str(source)], "whole-database backup helper", whole_env)
        whole_backup = self.only_backup(self.root / "whole-state")
        same_dump(before_whole, self.snapshot(source, "source-after-backup.sql"),
                  "Whole-database backup modified the source database.")
        self.restore(whole_backup, whole)
        require(self.column_metadata(whole) == before_columns,
                "Restored effective column types/defaults/charsets/collations/keys differ.")
        same_dump(before_whole, self.snapshot(whole, "restored-whole.sql"),
                  "Whole-database schemas or rows differ after restore.")
        same_dump(before_whole, self.snapshot(source, "source-after-whole.sql"),
                  "Recovery modified the source database.")
        same_dump(unrelated, self.snapshot(other, "other-after.sql"),
                  "Recovery or maintenance modified the unrelated website database.")
        count = len(self.tables(whole))
        require("outside_owner" in self.tables(whole), "Whole-database backup omitted the shared-database sentinel.")
        print(f"PASS: whole-database restore; {count} tables; canonical schema/data dumps match exactly.")
        print("PASS: source and unrelated website database unchanged by recovery; private checksums valid.")

    def cleanup(self) -> bool:
        ok = True
        for site in reversed(self.created):
            try:
                self.guard(site)
                self.wp_run(site, ["db", "drop", "--yes"], "drop this invocation's fixture database")
            except DrillError:
                ok = False
                print("Fixture cleanup was not confirmed; disposable CI service teardown is still required.", file=sys.stderr)
        return ok


def main() -> int:
    try:
        authorize(sys.argv[1:], os.environ)
    except DrillError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    old_umask = os.umask(0o077)
    ok = False
    try:
        with tempfile.TemporaryDirectory(prefix="pressgarden-recovery-") as temp:
            drill = Drill(Path(temp), os.environ["PRESS_TEST_DB_PASSWORD"])
            try:
                drill.exercise()
                ok = True
            except DrillError as exc:
                print("RECOVERY DRILL FAILED: " + str(exc), file=sys.stderr)
            finally:
                ok = drill.cleanup() and ok
    except (DrillError, OSError, ValueError) as exc:
        print("RECOVERY DRILL FAILED: " + str(exc), file=sys.stderr)
    finally:
        os.umask(old_umask)
    if ok:
        print("Isolated database recovery drill PASS. This does not verify any production backup.")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
