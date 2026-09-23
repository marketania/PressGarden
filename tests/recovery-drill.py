#!/usr/bin/env python3
"""Offline boundaries for the CI-only recovery drill; no WordPress or DB needed."""
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'tests/integration/database-restore.py'
spec = importlib.util.spec_from_file_location('recovery_drill', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecoveryBoundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.path = self.root / 'backup' / 'database.sql'
        self.path.parent.mkdir(mode=0o700)
        self.write_backup(b'-- inert fixture only\nSELECT 1;\n')
        self.auth = {'PRESSGARDEN_ALLOW_ISOLATED_RESTORE_TEST': '1', 'GITHUB_ACTIONS': 'true',
                     'GITHUB_REPOSITORY': 'marketania/PressGarden', 'PRESS_TEST_DB_PASSWORD': 'fixture-only'}

    def tearDown(self):
        self.temp.cleanup()

    def write_backup(self, data):
        self.path.write_bytes(data)
        self.path.chmod(0o600)
        record = self.path.with_name('database.sql.sha256')
        record.write_text(hashlib.sha256(data).hexdigest() + '  database.sql\n')
        record.chmod(0o600)

    def test_authorized_context_only(self):
        module.authorize([], self.auth)
        for key in self.auth:
            env = dict(self.auth)
            env.pop(key)
            with self.subTest(key=key), self.assertRaises(module.DrillError):
                module.authorize([], env)

    def test_reject_arguments_and_other_repository(self):
        for args, env in [(['example.com'], self.auth), (['--sql=/tmp/file.sql'], self.auth),
                          ([], dict(self.auth, GITHUB_REPOSITORY='someone/other'))]:
            with self.assertRaises(module.DrillError):
                module.authorize(args, env)

    def test_unattended_local_entrypoint_refuses_without_running_wp(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], env={}, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'opt-in', result.stderr)
        self.assertEqual(result.stdout, b'')

    def test_private_valid_backup(self):
        module.verify_backup(self.path, self.root)

    def test_corruption_is_rejected_before_import(self):
        self.path.write_bytes(b'-- modified fixture\nSELECT 2;\n')
        drill = object.__new__(module.Drill)
        drill.root = self.root
        drill.guard = Mock()
        drill.wp_run = Mock()
        with self.assertRaisesRegex(module.DrillError, 'checksum mismatch'):
            drill.restore(self.path, self.root / 'destination')
        drill.guard.assert_not_called()
        drill.wp_run.assert_not_called()

    def test_missing_checksum_and_wrong_filename(self):
        record = self.path.with_name('database.sql.sha256')
        record.unlink()
        with self.assertRaises(module.DrillError):
            module.verify_backup(self.path, self.root)
        record.write_text('0' * 64 + '  ../../outside.sql\n')
        record.chmod(0o600)
        with self.assertRaises(module.DrillError):
            module.verify_backup(self.path, self.root)

    def test_symbolic_links_refused(self):
        real = self.root / 'actual.sql'
        self.path.rename(real)
        self.path.symlink_to(real)
        with self.assertRaises(module.DrillError):
            module.verify_backup(self.path, self.root)

    def test_hardlinks_refused(self):
        os.link(self.path, self.root / 'second.sql')
        with self.assertRaises(module.DrillError):
            module.verify_backup(self.path, self.root)

    def test_unsafe_permissions_and_empty_files(self):
        self.path.chmod(0o644)
        with self.assertRaises(module.DrillError):
            module.verify_backup(self.path, self.root)
        self.path.chmod(0o600)
        self.path.write_bytes(b'')
        with self.assertRaises(module.DrillError):
            module.verify_backup(self.path, self.root)

    def test_path_escape_and_oversized_input(self):
        with self.assertRaises(module.DrillError):
            module.verify_backup(self.path, self.root / 'another-scope')
        with self.assertRaises(module.DrillError):
            module.verify_backup(self.root / 'backup' / '..' / 'backup' / 'database.sql', self.root)
        with self.path.open('wb') as handle:
            handle.truncate(64 * 1024 * 1024 + 1)
        with self.assertRaises(module.DrillError):
            module.verify_backup(self.path, self.root)

    def test_database_switching_sql_refused(self):
        for sql in (b'USE production;\n', b'CREATE DATABASE other;\n', b'DROP DATABASE other;\n'):
            self.write_backup(sql)
            with self.subTest(sql=sql), self.assertRaises(module.DrillError):
                module.verify_backup(self.path, self.root)

    def test_fixture_identity_and_loopback_only(self):
        site = self.root / 'fixture'
        site.mkdir()
        expected = 'pgrestore_ci_' + 'a' * 24 + '_scoped'
        good = {'DB_NAME': expected, 'DB_HOST': '127.0.0.1:3306'}
        module.validate_target(self.root, site, expected, good)
        for bad in ({'DB_NAME': 'production', 'DB_HOST': good['DB_HOST']},
                    {'DB_NAME': expected, 'DB_HOST': 'remote.example:3306'}):
            with self.assertRaises(module.DrillError):
                module.validate_target(self.root, site, expected, bad)
        with self.assertRaises(module.DrillError):
            module.validate_target(self.root, site, 'production', good)

    def test_never_restore_over_source_or_nonempty_database(self):
        drill = object.__new__(module.Drill)
        drill.root = self.root
        source = self.root / 'source'
        target = self.root / 'destination'
        drill.sites = {source: 'pgrestore_ci_' + 'a' * 24 + '_source',
                       target: 'pgrestore_ci_' + 'a' * 24 + '_scoped'}
        drill.guard = Mock()
        drill.tables = Mock(return_value=['existing_data'])
        drill.wp_run = Mock()
        with self.assertRaises(module.DrillError):
            drill.restore(self.path, source)
        with self.assertRaises(module.DrillError):
            drill.restore(self.path, target)
        drill.wp_run.assert_not_called()

    def test_ci_wiring_is_read_only_and_integration_is_separate(self):
        workflow = (REPO / '.github/workflows/ci.yml').read_text()
        self.assertIn('python3 tests/integration/database-restore.py', workflow)
        self.assertIn("PRESSGARDEN_ALLOW_ISOLATED_RESTORE_TEST: '1'", workflow)
        self.assertIn('contents: read', workflow)
        self.assertNotIn('contents: write', workflow)
        self.assertNotIn('*.sql', workflow)
        self.assertEqual(SCRIPT.parent.name, 'integration')


if __name__ == '__main__':
    unittest.main()
