#!/usr/bin/env python3
"""Unified cleanup CLI with real temporary files and an inert WP adapter."""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WP = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
raw=sys.argv[1:]
args=[a for a in raw if not a.startswith('--path=') and not a.startswith('--skip-') and a!='--no-color']
with open(os.environ['FIXTURE_CALLS'],'a') as f:f.write(json.dumps(raw)+'\n')
if args[:1]==['eval-file']:
 action=args[2]
 if action=='cleanup-report':
  if os.environ.get('FIXTURE_DB_FAULT')=='stderr':print('private-fixture-provider-output',file=sys.stderr)
  if os.environ.get('FIXTURE_DB_FAULT')=='invalid':print('\x1b[31mprivate-fixture-provider-output');sys.exit(0)
  print(json.dumps({'format':'PGDBCL1','expired':7,'revisions':2 if args[6]=='1' else 0},separators=(',',':')));sys.exit(0)
 if action=='identity':print('0'*64);sys.exit(0)
 if action=='plan':print('wp_options,wp_posts');sys.exit(0)
 if action=='cleanup':
  Path(os.environ['FIXTURE_MUTATION']).write_text('database cleanup dispatched')
  print('Expired transient option rows deleted (database affected-row count): 14');sys.exit(0)
 if action in ('status','check'):print('fixture database '+action);sys.exit(0)
if args[:2]==['db','export']:
 if os.environ.get('FIXTURE_DB_FAULT')=='backup':sys.exit(40)
 Path(args[2]).write_text('-- benign fixture SQL only\n');sys.exit(0)
sys.exit(99)
'''


class CleanupCLI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='garden-cli-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.site = self.base / 'fleet/example.test/public_html'
        for name in ['wp-admin', 'wp-content', 'wp-includes']:
            (self.site / name).mkdir(parents=True)
        for name in ['wp-load.php', 'wp-settings.php', 'wp-config.php']:
            (self.site / name).write_text('<?php // inert\n')
        (self.site / 'wp-includes/version.php').write_text('<?php $wp_version="7.1";\n')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        (self.bin / 'wp').write_text(WP)
        (self.bin / 'wp').chmod(0o755)
        self.calls = self.base / 'calls'
        self.mutation = self.base / 'mutation'
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/local/bin:/usr/bin:/bin',
                        HOME=str(self.base), PRESSGARDEN_CONFIG_FILE=str(self.base / 'absent'),
                        PRESSGARDEN_SCAN_ROOT=str(self.base / 'fleet'),
                        PRESSGARDEN_STATE_DIR=str(self.base / 'state'),
                        PRESSGARDEN_CACHE_DIR=str(self.base / 'cache'),
                        PRESSGARDEN_INTERACTIVE='0', PRESSGARDEN_PROGRESS='0', TERM='xterm',
                        FIXTURE_CALLS=str(self.calls), FIXTURE_MUTATION=str(self.mutation))
        for key in ['PRESSGARDEN_FORCE_COLOR', 'PRESSGARDEN_COLOR', 'PRESSGARDEN_NOCOLOR', 'NO_COLOR']:
            self.env.pop(key, None)
        for name in ['.DS_Store', 'debug.log.1', '.eslintcache', 'debug.log']:
            path = self.site / name
            path.write_text('benign old fixture\n')
            os.utime(path, (946684800, 946684800))

    def cli(self, *args):
        return subprocess.run(['bash', str(ROOT / 'pressgarden'), *args], env=self.env,
                              text=True, capture_output=True, timeout=30)

    def call_rows(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_default_covers_categories_in_one_readonly_table(self):
        r = self.cli('cleanup', 'example.test')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('Observed totals: 3 files', r.stdout)
        self.assertIn('7 expired transients', r.stdout)
        self.assertIn('revisions not selected', r.stdout)
        self.assertIn('READY', r.stdout)
        self.assertNotIn('CANDIDATE', r.stdout)
        self.assertEqual(r.stdout.count('PREVIEW:'), 1)
        self.assertFalse(self.mutation.exists())
        self.assertFalse((self.base / 'state/backups').exists())
        self.assertTrue((self.site / '.DS_Store').exists())
        self.assertTrue(all('cleanup-report' in row for row in self.call_rows()))

    def test_narrow_terminal_keeps_each_site_on_two_readable_lines(self):
        self.env['COLUMNS'] = '80'
        r = self.cli('cleanup', '--color=always')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('\x1b[', r.stdout)
        lines = re.sub(r'\x1b\[[0-9;]*m', '', r.stdout).splitlines()
        row = lines.index('  example.test')
        self.assertIn('READY', lines[row + 1])
        self.assertIn('Files 3 / 57 B · Expired 7 · Rev - · Review 0', lines[row + 1])
        self.assertLessEqual(len(lines[row + 1]), 80)
        self.assertFalse(self.mutation.exists())

    def test_wide_terminal_retains_aligned_table(self):
        self.env['COLUMNS'] = '140'
        r = self.cli('cleanup')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        header = next(line for line in r.stdout.splitlines() if line.startswith('  SITE'))
        row = next(line for line in r.stdout.splitlines() if line.startswith('  example.test'))
        self.assertIn('FILE BYTES', header)
        self.assertIn('READY', row)
        self.assertLessEqual(len(row), 100)
        self.assertNotIn('Files ', row)

    def test_long_nested_label_uses_compact_layout_without_truncation(self):
        self.env['COLUMNS'] = '140'
        domain = 'long-client-maintenance.example.test'
        nested = self.base / 'fleet' / domain / 'public_html/storefront'
        shutil.copytree(self.site, nested)
        r = self.cli('cleanup')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        lines = r.stdout.splitlines()
        for label in ['example.test', domain + '/storefront']:
            row = lines.index('  ' + label)
            self.assertIn('READY', lines[row + 1])
            self.assertIn('Files 3 / 57 B', lines[row + 1])
        self.assertIn('Observed totals: 6 files', r.stdout)

    def test_files_only_needs_no_database_provider(self):
        r = self.cli('cleanup', '-files', '--verbose', 'example.test')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('Observed totals: 1 files', r.stdout)
        self.assertIn('CANDIDATE .DS_Store', r.stdout)
        self.assertNotIn('CANDIDATE debug.log.1', r.stdout)
        self.assertFalse(self.calls.exists())

    def test_log_selector_does_not_delete_metadata_or_current_log(self):
        r = self.cli('cleanup', '-logs', '--execute', 'example.test')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((self.site / 'debug.log.1').exists())
        for name in ['.DS_Store', 'debug.log', '.eslintcache']:
            self.assertTrue((self.site / name).exists(), name)
        self.assertTrue(list((self.base / 'state/backups/file-cleanup').glob('*/manifest.json')))
        self.assertFalse(self.calls.exists())

    def test_category_filters_combine(self):
        r = self.cli('cleanup', '--files', '--logs', '--verbose', 'example.test')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('Observed totals: 2 files', r.stdout)
        self.assertNotIn('CANDIDATE .eslintcache', r.stdout)
        self.assertFalse(self.calls.exists())

    def test_db_only_does_not_inspect_file_tree(self):
        path = self.site
        for _ in range(26):
            path /= 'deep'
            path.mkdir()
        r = self.cli('cleanup', '--db', 'example.test')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('7 expired transients', r.stdout)
        self.assertNotIn('File inspection incomplete', r.stdout)

    def test_revision_selection_is_explicit_and_scoped(self):
        r = self.cli('cleanup', '-db', '--revisions', '--blog=2', 'example.test')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('2 revision candidates', r.stdout)
        self.assertIn('2', self.call_rows()[0])
        self.calls.unlink()
        r = self.cli('cleanup', '-logs', '--revisions', 'example.test')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertFalse(self.calls.exists())

    def test_untrusted_db_response_is_incomplete_without_echoing_raw_data(self):
        for fault in ['invalid', 'stderr']:
            self.env['FIXTURE_DB_FAULT'] = fault
            r = self.cli('cleanup', 'example.test')
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
            self.assertIn('INCOMPLETE', r.stdout)
            self.assertIn('Observed totals: 3 files', r.stdout)
            self.assertNotIn('private-fixture-provider-output', r.stdout + r.stderr)
            self.assertNotIn('\x1b', r.stdout)

    def test_failed_backup_prevents_db_and_later_file_cleanup(self):
        self.env['FIXTURE_DB_FAULT'] = 'backup'
        r = self.cli('cleanup', '--execute', 'example.test')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertFalse(self.mutation.exists())
        self.assertTrue((self.site / '.DS_Store').exists())
        self.assertTrue((self.site / 'debug.log.1').exists())

    def test_file_review_prevents_any_combined_mutation(self):
        path=self.site/'.DS_Store'
        path.write_text('<?php /* inert evidence */')
        os.utime(path,(946684800,946684800))
        r=self.cli('cleanup','--execute','example.test')
        self.assertEqual(r.returncode,2,r.stdout+r.stderr)
        self.assertFalse(self.mutation.exists())
        self.assertFalse((self.base/'state/backups').exists())
        self.assertTrue((self.site/'debug.log.1').exists())

    def test_deep_file_scan_failure_prevents_db_mutation(self):
        path=self.site
        for _ in range(26):
            path/='deep';path.mkdir()
        r=self.cli('cleanup','--execute','example.test')
        self.assertEqual(r.returncode,2,r.stdout+r.stderr)
        self.assertFalse(self.mutation.exists())
        self.assertFalse((self.base/'state/backups').exists())

    def test_help_never_calls_provider_or_updater(self):
        self.env['PRESSGARDEN_UPDATE_ARCHIVE'] = str(self.base / 'missing.tar.gz')
        for args in [('update', '--help'), ('cleanup', '--execute', '--help'), ('cache', 'clear', '--help')]:
            r = self.cli(*args)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mutation.exists())
        self.assertFalse((ROOT / '.pressgarden-update.lock').exists())

    def test_invalid_targets_and_options_never_broaden(self):
        for args in [('cleanup', '--files', ''), ('cleanup', '--db', 'missing.test'),
                     ('cleanup', '-db', '--target=',), ('cleanup', '--files', '--bogus'),
                     ('cleanup', '--logs', 'example.test', 'another.test'),
                     ('cleanup', 'status', '--execute', 'example.test'),
                     ('cleanup', 'preview', '--execute', '-logs', 'example.test'),
                     ('update', '--bogus')]:
            r = self.cli(*args)
            self.assertEqual(r.returncode, 2, (args, r.stdout, r.stderr))
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mutation.exists())

    def test_color_modes_and_no_color(self):
        self.assertNotIn('\x1b', self.cli('cleanup', '-files').stdout)
        self.assertIn('\x1b[', self.cli('cleanup', '-files', '--color=always').stdout)
        self.assertNotIn('\x1b', self.cli('cleanup', '-files', '--color=never').stdout)
        self.env['PRESSGARDEN_FORCE_COLOR'] = '1'
        self.env['NO_COLOR'] = '1'
        self.assertNotIn('\x1b', self.cli('help').stdout)
        self.assertNotIn('\x1b', self.cli('help', '--color=always').stdout)
        self.env.pop('NO_COLOR')
        self.env['PRESSGARDEN_FORCE_COLOR'] = '0'
        self.assertNotIn('\x1b', self.cli('help').stdout)
        self.env['TERM'] = 'dumb'
        self.assertNotIn('\x1b', self.cli('help').stdout)
        self.assertEqual(self.cli('help', '--color=invalid').returncode, 2)

    def test_review_status_retains_suspicious_files(self):
        path = self.site / '.DS_Store'
        path.write_text('<?php /* inert evidence */')
        os.utime(path, (946684800, 946684800))
        r = self.cli('cleanup', '-files', '--verbose', 'example.test')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('REVIEW', r.stdout)
        self.assertTrue(path.exists())

    def test_short_help_and_advanced_help(self):
        short = self.cli('help')
        full = self.cli('help', 'all')
        self.assertEqual(short.returncode, 0)
        self.assertLess(len(short.stdout.splitlines()), len(full.stdout.splitlines()))
        self.assertNotIn('litespeed AREA', short.stdout)
        self.assertIn('litespeed AREA', full.stdout)

    def test_status_shortcuts_preserve_database_action(self):
        for verb, expected in [('status', 'status'), ('check', 'check')]:
            r = self.cli(verb, '-db', 'example.test')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('fixture database ' + expected, r.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
