#!/usr/bin/env python3
"""Unified cleanup CLI with real temporary files and an inert WP adapter."""
from pathlib import Path
import json
import os
import re
import shlex
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
if args[:2]==['core','is-installed']:sys.exit(0)
if args[:2]==['plugin','is-installed']:sys.exit(1)
if args[:2]==['theme','list']:
 fault=os.environ.get('FIXTURE_THEME_FAULT')
 if fault=='controls':print('fixture-theme\x1b[2J\u202e active 1.0');sys.exit(0)
 if fault=='stderr':print('private-theme-fixture-output',file=sys.stderr);sys.exit(0)
 if fault=='oversize':print('x'*4194305);sys.exit(0)
 print('fixture-theme active 1.0');sys.exit(0)
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

    def tty_cli(self, answers, *args):
        env = dict(self.env, PRESSGARDEN_INTERACTIVE='1')
        cmd = shlex.join(['bash', str(ROOT / 'pressgarden'), *args])
        return subprocess.run(['script', '-qec', cmd, '/dev/null'], env=env, input=answers,
                              text=True, capture_output=True, timeout=30)

    @unittest.skipUnless(shutil.which('script'), 'script(1) pty helper unavailable')
    def test_terminal_preview_asks_per_category_and_defaults_to_no(self):
        r = self.tty_cli('\n', 'cleanup', '-db', 'example.test')
        self.assertEqual(r.stdout.count('Clean now?'), 1, r.stdout)
        self.assertIn('Expired database transients: 7', r.stdout)
        self.assertFalse(self.mutation.exists())
        r = self.tty_cli('y\ny\n', 'cleanup', '-db', 'example.test')
        self.assertTrue(self.mutation.exists(), r.stdout)
        self.assertIn('COMPLETE', r.stdout)
        self.assertTrue(list((self.base / 'state').rglob('*.sql*')), r.stdout)
        r = self.cli('cleanup', '-db', 'example.test')
        self.assertNotIn('Clean now?', r.stdout + r.stderr)

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

    def test_unselected_revisions_stay_unselected_when_database_is_incomplete(self):
        self.env['FIXTURE_DB_FAULT'] = 'invalid'
        self.env['COLUMNS'] = '80'
        for flags, expected in [((), 'Rev -'), (('--revisions',), 'Rev ?')]:
            r = self.cli('cleanup', '-db', *flags, 'example.test')
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
            self.assertIn('Expired ? · ' + expected, r.stdout)

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
                     ('cleanup', '--target', '--color=never', 'all'),
                     ('cleanup', '--execute', '--target', '--color=never', 'all'),
                     ('update', '--bogus')]:
            r = self.cli(*args)
            self.assertEqual(r.returncode, 2, (args, r.stdout, r.stderr))
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mutation.exists())

    def test_doctor_empty_or_fully_excluded_scope_is_incomplete(self):
        empty = self.base / 'empty'
        empty.mkdir()
        r = self.cli('doctor', str(empty))
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn('No non-excluded WordPress installations', r.stdout)
        self.env['PRESSGARDEN_EXCLUDE'] = 'example.test'
        r = self.cli('doctor')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn('Selected installations: 0', r.stdout)
        self.assertFalse(self.calls.exists())

    def test_doctor_accepts_named_target_and_rejects_duplicate_or_unknown_options(self):
        r = self.cli('doctor', '--target', 'example.test')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('Selected installations: 1', r.stdout)
        for args in [('doctor', '--target'), ('doctor', '--bogus'),
                     ('doctor', '--target', 'example.test', 'all')]:
            r = self.cli(*args)
            self.assertEqual(r.returncode, 2, (args, r.stdout, r.stderr))
        self.assertFalse(self.calls.exists())

    def test_config_refuses_invalid_root_without_success_output(self):
        link = self.base / 'linked'
        link.symlink_to(self.base / 'fleet', target_is_directory=True)
        self.env['PRESSGARDEN_SCAN_ROOT'] = str(link)
        r = self.cli('config')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn('symlink target component refused', r.stderr)
        self.assertNotIn('Root:', r.stdout)

    def test_invalid_config_is_not_partly_executed_or_used_for_dispatch(self):
        config = self.base / 'broken-config'
        sentinel = self.base / 'config-executed'
        config.write_text('touch ' + shlex.quote(str(sentinel)) + '\nif then\n')
        self.env['PRESSGARDEN_CONFIG_FILE'] = str(config)
        for args in [('cleanup', '--execute'), ('status',), ('config',)]:
            r = self.cli(*args)
            self.assertEqual(r.returncode, 2, (args, r.stdout, r.stderr))
            self.assertIn('Invalid shell syntax', r.stderr)
        direct = subprocess.run(['bash', str(ROOT / 'checks/cleanup-all.sh'), 'preview', '--files'],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(direct.returncode, 2, direct.stdout + direct.stderr)
        r = self.cli('config-new')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(sentinel.exists())
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mutation.exists())
        self.assertTrue((self.site / '.DS_Store').exists())

    def test_config_source_failure_stops_entrypoint_and_internal_runner(self):
        config = self.base / 'failed-config'
        config.write_text('PRESSGARDEN_CLEANUP_DAYS=60\nreturn 7\n')
        self.env['PRESSGARDEN_CONFIG_FILE'] = str(config)
        r = self.cli('cleanup', '--execute')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        direct = subprocess.run(['bash', str(ROOT / 'checks/cleanup-all.sh'), 'execute', '--files'],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(direct.returncode, 2, direct.stdout + direct.stderr)
        self.assertIn('config failed to load', direct.stderr)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mutation.exists())
        self.assertTrue((self.site / '.DS_Store').exists())

    def test_existing_invalid_config_file_type_never_uses_defaults(self):
        directory = self.base / 'directory-config'
        directory.mkdir()
        dangling = self.base / 'dangling-config'
        dangling.symlink_to(self.base / 'missing-config')
        for config in [directory, dangling]:
            self.env['PRESSGARDEN_CONFIG_FILE'] = str(config)
            r = self.cli('cleanup', '--execute')
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
            self.assertIn('not a readable regular file', r.stderr)
            direct = subprocess.run(['bash', str(ROOT / 'checks/cleanup-all.sh'), 'execute', '--files'],
                                    env=self.env, text=True, capture_output=True, timeout=30)
            self.assertEqual(direct.returncode, 2, direct.stdout + direct.stderr)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mutation.exists())
        self.assertTrue((self.site / '.DS_Store').exists())

    @unittest.skipIf(os.geteuid() == 0, 'Unreadable file behavior requires a nonroot account')
    def test_unreadable_saved_config_never_uses_defaults(self):
        config = self.base / 'unreadable-config'
        config.write_text('PRESSGARDEN_SCAN_ROOT="/unreadable-config-must-not-run"\n')
        config.chmod(0)
        self.addCleanup(config.chmod, 0o600)
        self.env['PRESSGARDEN_CONFIG_FILE'] = str(config)
        r = self.cli('cleanup', '--execute')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn('not a readable regular file', r.stderr)
        direct = subprocess.run(['bash', str(ROOT / 'checks/cleanup-all.sh'), 'execute', '--files'],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(direct.returncode, 2, direct.stdout + direct.stderr)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mutation.exists())
        self.assertTrue((self.site / '.DS_Store').exists())

    def test_valid_shell_config_and_exported_overrides_still_work(self):
        config = self.base / 'valid-config'
        config.write_text('garden_age() { printf 60; }\nPRESSGARDEN_CLEANUP_DAYS="$(garden_age)"\n'
                          'PRESSGARDEN_SCAN_ROOT="/config-root-must-not-win"\n'
                          'PRESSGARDEN_EXCLUDE="example.test"\n')
        self.env['PRESSGARDEN_CONFIG_FILE'] = str(config)
        self.env['PRESSGARDEN_EXCLUDE'] = ''
        r = self.cli('cleanup', '-files')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('age: 60+ days', r.stdout)
        self.env['PRESSGARDEN_CLEANUP_DAYS'] = '45'
        r = self.cli('cleanup', '-files')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('age: 45+ days', r.stdout)

    def test_exported_multiline_scan_root_is_refused_without_dispatch(self):
        config = self.base / 'valid-config'
        config.write_text('PRESSGARDEN_SCAN_ROOT=' + shlex.quote(str(self.base / 'fleet')) + '\n')
        self.env['PRESSGARDEN_CONFIG_FILE'] = str(config)
        for suffix in ['\ninvalid', '\n']:
            self.env['PRESSGARDEN_SCAN_ROOT'] = str(self.base / 'fleet') + suffix
            for args in [('cleanup',), ('cleanup', '--execute')]:
                r = self.cli(*args)
                self.assertEqual(r.returncode, 2, (args, r.stdout, r.stderr))
            for action in ['preview', 'execute']:
                direct = subprocess.run(['bash', str(ROOT / 'checks/cleanup-all.sh'), action],
                                        env=self.env, text=True, capture_output=True, timeout=30)
                self.assertEqual(direct.returncode, 2, direct.stdout + direct.stderr)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mutation.exists())
        self.assertFalse((self.base / 'state/backups').exists())
        self.assertTrue((self.site / '.DS_Store').exists())

    def test_exported_multiline_exclusions_preserve_every_site(self):
        second = self.base / 'fleet/second.test/public_html'
        included = self.base / 'fleet/included.test/public_html'
        shutil.copytree(self.site, second)
        shutil.copytree(self.site, included)
        config = self.base / 'valid-config'
        config.write_text('PRESSGARDEN_EXCLUDE="included.test"\n')
        self.env['PRESSGARDEN_CONFIG_FILE'] = str(config)
        self.env['PRESSGARDEN_EXCLUDE'] = 'example.test\nsecond.test\n'
        commands = [(['bash', str(ROOT / 'pressgarden'), 'cleanup', '-db']),
                    (['bash', str(ROOT / 'checks/cleanup-all.sh'), 'preview', '--db'])]
        for command in commands:
            r = subprocess.run(command, env=self.env, text=True, capture_output=True, timeout=30)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('1 selected site(s)', r.stdout)
            paths = [arg for row in self.call_rows() for arg in row if arg.startswith('--path=')]
            self.assertEqual(paths, ['--path=' + str(included)])
            self.calls.unlink()
        self.assertFalse(self.mutation.exists())

    def test_readonly_config_cannot_discard_exported_scope(self):
        config = self.base / 'readonly-config'
        config.write_text('readonly PRESSGARDEN_SCAN_ROOT=' + shlex.quote(str(self.site)) + '\n')
        self.env['PRESSGARDEN_CONFIG_FILE'] = str(config)
        r = self.cli('cleanup', '--execute')
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        direct = subprocess.run(['bash', str(ROOT / 'checks/cleanup-all.sh'), 'execute'],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(direct.returncode, 2, direct.stdout + direct.stderr)
        self.assertIn('exported PressGarden setting', r.stderr + direct.stderr)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mutation.exists())
        self.assertTrue((self.site / '.DS_Store').exists())

    def test_status_sanitizes_theme_controls_and_refuses_bad_output(self):
        self.env['FIXTURE_THEME_FAULT'] = 'controls'
        r = self.cli('status', 'example.test')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn('\x1b', r.stdout)
        self.assertNotIn('\u202e', r.stdout)
        self.assertIn('fixture-theme', r.stdout)
        for fault in ['stderr', 'oversize']:
            self.env['FIXTURE_THEME_FAULT'] = fault
            r = self.cli('status', 'example.test')
            self.assertEqual(r.returncode, 2, (fault, r.stdout, r.stderr))
            self.assertIn('INCOMPLETE: theme inventory', r.stdout)
            self.assertNotIn('private-theme-fixture-output', r.stdout + r.stderr)
            self.assertLess(len(r.stdout), 5000)

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

    def test_help_topics_are_focused_and_do_not_bootstrap_wordpress(self):
        expected = {'db': 'db ACTION', 'cache': 'cache ACTION', 'status': 'Read-only checks'}
        for topic, heading in expected.items():
            r = self.cli('help', topic)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn(heading, r.stdout)
            self.assertNotIn('litespeed AREA', r.stdout)
        self.assertFalse(self.calls.exists())

    def test_status_shortcuts_preserve_database_action(self):
        for verb, expected in [('status', 'status'), ('check', 'check')]:
            r = self.cli(verb, '-db', 'example.test')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('fixture database ' + expected, r.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
