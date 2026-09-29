#!/usr/bin/env python3
"""Inert provider-output/readback tests: real CLI, files and FIFO, no WordPress/network."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'lib/litespeed-output.php'

class LiteSpeedOutput(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pg-output-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def helper(self, mode, data=b'', args=()):
        p = subprocess.Popen(['php', str(HELPER), mode, *map(str, args)], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            out, err = p.communicate(data, timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL); p.communicate()
            self.fail('Readback/display blocked on an unsafe file')
        return p.returncode, out, err

    def test_terminal_controls_and_bidi_are_inert_in_plain_response(self):
        rc, out, err = self.helper('redact', 'café\t\x1b]52;c;inert\x07\r\u202efake\u009b2J\n'.encode())
        self.assertEqual(rc, 0, err)
        for unsafe in (b'\x1b', b'\x07', b'\r', b'\t', '\u202e'.encode(), '\u009b'.encode()):
            self.assertNotIn(unsafe, out)
        self.assertIn('café'.encode(), out); self.assertIn(b'\\x1B', out)

    def test_invalid_utf8_control_bytes_are_represented(self):
        rc, out, _ = self.helper('redact', b'path\xff\x9b2J\n')
        self.assertEqual(rc, 0); self.assertNotIn(b'\xff', out); self.assertNotIn(b'\x9b', out)
        self.assertIn(b'\\xFF', out)

    def test_nested_json_redaction_and_unicode_remain_valid(self):
        value = {'cache': True, 'nested': {'api_key': 'inert-secret', 'label': 'café\u202e'}, 'rows': [1, 2]}
        rc, out, _ = self.helper('redact', json.dumps(value).encode())
        self.assertEqual(rc, 0); self.assertNotIn(b'inert-secret', out)
        decoded = json.loads(out)
        self.assertEqual(decoded['nested']['api_key'], '[REDACTED]')
        self.assertEqual(decoded['cache'], True); self.assertNotIn('\u202e'.encode(), out)

    def test_plain_sensitive_line_redaction_still_preserves_safe_settings(self):
        rc, out, _ = self.helper('redact', b'cache=true\napi_key=inert-secret\n')
        self.assertEqual(rc, 0); self.assertIn(b'cache=true', out); self.assertNotIn(b'inert-secret', out)

    def test_valid_readback_normalization(self):
        target = self.base / 'value'
        for expected, actual in ((b'true', b'1\r\n'), (b'false', b'false\n'), (b'', b"''\n"), (b'caf\xc3\xa9', b'caf\xc3\xa9\n')):
            target.write_bytes(actual)
            self.assertEqual(self.helper('verify', expected, (target,))[0], 0)
        self.assertEqual(self.helper('verify', b'different', (target,))[0], 2)

    def test_readback_refuses_symlinks_hardlinks_and_linked_parents(self):
        original = self.base / 'original'; original.write_bytes(b'true\n')
        link = self.base / 'link'; link.symlink_to(original)
        hard = self.base / 'hard'; os.link(original, hard)
        real = self.base / 'real'; real.mkdir(); (real / 'value').write_bytes(b'true\n')
        parent = self.base / 'parent'; parent.symlink_to(real, target_is_directory=True)
        for path in (link, hard, parent / 'value'):
            with self.subTest(path=path.name):
                rc, out, _ = self.helper('verify', b'true', (path,))
                self.assertEqual(rc, 2); self.assertEqual(out, b'')
        self.assertEqual(original.read_bytes(), b'true\n')

    def test_readback_refuses_fifo_before_open(self):
        path = self.base / 'pipe'; os.mkfifo(path)
        self.assertEqual(self.helper('verify', b'true', (path,))[0], 2)

    def test_readback_oversize_and_missing_sources_are_incomplete(self):
        path = self.base / 'huge'
        with path.open('wb') as f: f.truncate(1048577)
        self.assertEqual(self.helper('verify', b'true', (path,))[0], 2)
        self.assertEqual(self.helper('verify', b'true', (self.base / 'missing',))[0], 2)

    def cli(self, mode, action=('option', 'all')):
        fleet = self.base / 'fleet'
        for label in ('example.test', 'other.test'):
            site = fleet / label / 'public_html'
            for d in ('wp-admin', 'wp-content', 'wp-includes'): (site / d).mkdir(parents=True, exist_ok=True)
            for f in ('wp-load.php', 'wp-settings.php', 'wp-config.php'): (site / f).write_text('<?php // inert\n')
            (site / 'wp-includes/version.php').write_text('<?php $wp_version="7.1";\n')
        bindir = self.base / 'bin'; bindir.mkdir(exist_ok=True)
        stub = bindir / 'wp'
        stub.write_text(r'''#!/usr/bin/env python3
import os,sys
from pathlib import Path
args=sys.argv[1:];a=[x for x in args if not x.startswith('--')]
site=next((x.split('=',1)[1] for x in args if x.startswith('--path=')),os.getcwd())
m=os.environ['PG_OUTPUT_MODE'];base=Path(os.environ['PG_OUTPUT_WORK'])
if a[:2]==['core','is-installed']:sys.exit(1 if '--network' in args else 0)
if a[0]=='plugin':
 if a[1]=='get':print('7.5.0')
 sys.exit(0)
if a[0]=='help':sys.exit(0)
if a[0]!='litespeed-option':sys.exit(99)
if a[1]=='export':
 f=next(x.split('=',1)[1] for x in args if x.startswith('--filename='));Path(f).write_text('cache=true\n');sys.exit(0)
if a[1]=='get':print('false');sys.exit(0)
if a[1] in ('set','reset'):
 with (base/'changed').open('a') as f:f.write(site+'\n')
if m=='large' and 'example.test' in site:sys.stdout.write('A'*4194305)
elif m=='controls':sys.stdout.buffer.write(b'Status: \x1b[2J\x07\rnot-a-command\n')
elif m=='many':print('\n'.join('line %s'%i for i in range(300)))
else:print('safe response')
if m=='failed':sys.exit(37)
''')
        stub.chmod(0o755)
        env = dict(os.environ, PATH=str(bindir)+':/usr/local/bin:/usr/bin:/bin', HOME=str(self.base),
                   PG_OUTPUT_MODE=mode, PG_OUTPUT_WORK=str(self.base),
                   PRESSGARDEN_SCAN_ROOT=str(fleet), PRESSGARDEN_CONFIG_FILE=str(self.base/'missing-config'),
                   PRESSGARDEN_STATE_DIR=str(self.base/'state'), PRESSGARDEN_CACHE_DIR=str(self.base/'cache'),
                   PRESSGARDEN_INTERACTIVE='0', PRESSGARDEN_PROGRESS='0', PRESSGARDEN_NOCOLOR='1')
        return subprocess.run(['bash', str(ROOT/'pressgarden'), 'litespeed', *action, '--target', 'all'],
                              env=env, capture_output=True, timeout=20)

    def test_actual_cli_does_not_emit_provider_terminal_commands(self):
        r = self.cli('controls'); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(b'\x1b', r.stdout); self.assertNotIn(b'\x07', r.stdout); self.assertNotIn(b'\r', r.stdout)
        self.assertIn(b'\\x1B', r.stdout)

    def test_read_only_oversized_output_is_incomplete_and_other_site_continues(self):
        r = self.cli('large'); self.assertEqual(r.returncode, 2, r.stdout[-1500:]+r.stderr)
        self.assertIn(b'OUTPUT INCOMPLETE', r.stdout+r.stderr)
        self.assertIn(b'output failures 1', r.stdout); self.assertIn(b'safe response', r.stdout)
        self.assertNotIn(b'A'*80, r.stdout)

    def test_completed_mutation_with_output_failure_is_not_retried_or_reported_unchanged(self):
        r = self.cli('large', ('option','reset'))
        self.assertEqual(r.returncode, 2, r.stdout[-1500:]+r.stderr)
        self.assertEqual(len((self.base/'changed').read_text().splitlines()), 2); self.assertIn(b'output failures 1', r.stdout)
        self.assertIn(b'execution failures 0', r.stdout); self.assertIn(b'COMMAND COMPLETED', r.stdout)

    def test_intentional_mutation_display_cap_is_not_a_failure(self):
        r = self.cli('many', ('option','reset'))
        self.assertEqual(r.returncode, 0, r.stderr); self.assertIn(b'line 0', r.stdout)
        self.assertNotIn(b'line 299', r.stdout); self.assertIn(b'output omitted', r.stdout)

    def test_real_execution_failure_remains_distinct(self):
        r = self.cli('failed'); self.assertEqual(r.returncode, 2)
        self.assertIn(b'execution failures 2', r.stdout); self.assertIn(b'exit 37', r.stdout)

if __name__ == '__main__': unittest.main(verbosity=2)
