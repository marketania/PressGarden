#!/usr/bin/env python3
"""Public CLI regressions; only inert temporary fixtures, never live sites."""
from pathlib import Path
import fcntl
import hashlib
import os
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = (ROOT / 'PRODUCT').read_text().strip()
PROGRAM = PRODUCT.lower()
PREFIX = PRODUCT.upper()

class PublicBoundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='press-public-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.fleet = self.base / 'sites'
        self.site = self.fleet / 'alpha.example/public_html'
        self.make_site(self.site)
        self.env = {'PATH':'/usr/local/bin:/usr/bin:/bin', 'HOME':str(self.base),
                    'LANG':'C.UTF-8', PREFIX+'_SCAN_ROOT':str(self.fleet),
                    PREFIX+'_CONFIG_FILE':str(self.base/'absent-config'),
                    PREFIX+'_STATE_DIR':str(self.base/'state'),
                    PREFIX+'_CACHE_DIR':str(self.base/'cache'),
                    PREFIX+'_INTERACTIVE':'0', PREFIX+'_PROGRESS':'0', PREFIX+'_NOCOLOR':'1'}

    def make_site(self, site):
        for d in ['wp-admin', 'wp-content', 'wp-includes']:
            (site/d).mkdir(parents=True, exist_ok=True)
        for f in ['wp-load.php', 'wp-settings.php', 'wp-config.php']:
            (site/f).write_text('<?php\n')
        (site/'wp-includes/version.php').write_text('<?php $wp_version="7.1";\n')
        file=site/'.DS_Store'; file.write_text('Inert metadata fixture, not client data.\n')
        os.utime(file, (time.time()-90*86400,)*2)

    def run_cli(self, *args):
        return subprocess.run(['bash', str(ROOT/PROGRAM), *map(str,args)], env=self.env,
                              text=True, capture_output=True, timeout=30)

    def test_explicit_empty_sites_target_is_refused(self):
        r=self.run_cli('sites','')
        self.assertEqual(r.returncode,2,r.stdout+r.stderr)
        self.assertNotIn('alpha.example',r.stdout)

    def test_invalid_directory_never_falls_back_to_fleet(self):
        link=self.base/'linked'; link.symlink_to(self.site,target_is_directory=True)
        for target in [link, link/'wp-content', str(self.site)+'\ninvalid']:
            with self.subTest(target=str(target)):
                r=self.run_cli('sites',target)
                self.assertEqual(r.returncode,2,r.stdout+r.stderr)
                self.assertNotIn('alpha.example',r.stdout)

    def test_default_and_valid_directory_inventory_work(self):
        for args in [('sites',),('sites',self.fleet)]:
            r=self.run_cli(*args)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            self.assertIn('alpha.example',r.stdout)

    def test_directory_target_preserves_fleet_relative_exclusion(self):
        child=self.site/'shop'; self.make_site(child)
        self.env[PREFIX+'_EXCLUDE']='alpha.example/shop'
        r=self.run_cli('sites',self.site)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertNotIn(str(child),r.stdout)
        self.assertIn(str(self.site),r.stdout)
        if PRODUCT=='PressGarden':
            r=self.run_cli('cleanup','execute',self.site)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            self.assertTrue((child/'.DS_Store').is_file())
            self.assertFalse((self.site/'.DS_Store').exists())

    def test_uninstall_refuses_recovery_markers(self):
        dest=self.base/'installation'; env=dict(self.env)
        env[PREFIX+'_INSTALL_SOURCE']=str(ROOT)
        env[PREFIX+'_INSTALL_PREFIX']=str(dest)
        r=subprocess.run(['bash',str(ROOT/'install.sh')],env=env,text=True,capture_output=True,timeout=45)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        program=dest/PROGRAM; before=hashlib.sha256(program.read_bytes()).hexdigest()
        lock=dest/('.'+PROGRAM+'-update.lock')
        for kind in ['directory','file','dangling-link']:
            with self.subTest(kind=kind):
                if kind=='directory': lock.mkdir()
                elif kind=='file': lock.write_text('inert marker')
                else: lock.symlink_to(self.base/'absent-target')
                r=subprocess.run(['bash',str(dest/'uninstall.sh'),'--yes'],env=env,text=True,capture_output=True,timeout=20)
                self.assertEqual(r.returncode,2,r.stdout+r.stderr)
                self.assertTrue(program.is_file())
                self.assertEqual(hashlib.sha256(program.read_bytes()).hexdigest(),before)
                lock.rmdir() if kind=='directory' else lock.unlink()

    @unittest.skipUnless(PRODUCT=='PressGarden','maintenance-specific')
    def test_cleanup_keeps_excluded_child_under_named_parent(self):
        child=self.site/'shop';self.make_site(child)
        self.env[PREFIX+'_EXCLUDE']='alpha.example/shop'
        original=(child/'.DS_Store').read_bytes()
        for action in ['preview','execute']:
            r=self.run_cli('cleanup',action,'alpha.example')
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            self.assertNotIn('CANDIDATE shop/',r.stdout)
            self.assertEqual((child/'.DS_Store').read_bytes(),original)
        self.assertFalse((self.site/'.DS_Store').exists())

    @unittest.skipUnless(PRODUCT=='PressGarden','maintenance-specific')
    def test_cleanup_fleet_keeps_absolute_child_exclusion(self):
        child=self.site/'shop';self.make_site(child)
        self.env[PREFIX+'_EXCLUDE']=str(child)
        r=self.run_cli('cleanup','execute','all')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertTrue((child/'.DS_Store').exists())
        self.assertFalse((self.site/'.DS_Store').exists())

    @unittest.skipUnless(PRODUCT=='PressHarden','policy-specific')
    def test_auto_update_preferences_respect_real_writer_lock(self):
        bindir=self.base/'bin';bindir.mkdir();wp=bindir/'wp'
        wp.write_text('''#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$TEST_CALLS"
case "$1" in
 plugin|theme)
  [ "$2" = auto-updates ] || exit 90
  case "$3" in
   status)
    case " $* " in
     *' --field=name '*) [ "$(cat "$TEST_AUTO_STATE")" = 0 ] || echo demo ;;
     *' --enabled-only '*) cat "$TEST_AUTO_STATE" ;;
     *) echo 1 ;;
    esac ;;
   disable) echo 0 > "$TEST_AUTO_STATE" ;;
   enable) echo 1 > "$TEST_AUTO_STATE" ;;
   *) exit 90 ;;
  esac ;;
 config) exit 1 ;;
 *) exit 90 ;;
esac
''')
        wp.chmod(0o755)
        self.env['PATH']=str(bindir)+':'+self.env['PATH']
        self.env['TEST_CALLS']=str(self.base/'calls')
        value=self.base/'auto-state';self.env['TEST_AUTO_STATE']=str(value)
        locks=self.base/'state/operation-locks';locks.mkdir(parents=True,mode=0o700)
        (self.base/'state').chmod(0o700)
        lock=locks/(hashlib.sha256(str(self.site).encode()).hexdigest()+'.lock');lock.touch(mode=0o600)
        with lock.open('r+') as held:
            fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
            for area in ['plugins','themes']:
                value.write_text('1\n')
                r=self.run_cli('auto-updates',area,'disable','alpha.example')
                self.assertEqual(r.returncode,2,r.stdout+r.stderr)
                self.assertEqual(value.read_text(),'1\n')
                self.assertIn('lock',r.stdout+r.stderr)
        r=self.run_cli('auto-updates','plugins','disable','alpha.example')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(value.read_text(),'0\n')

if __name__=='__main__':
    unittest.main(verbosity=2)
