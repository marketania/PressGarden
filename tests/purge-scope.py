#!/usr/bin/env python3
"""Real CLI + real scope helper; provider calls recorded by an inert adapter."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PurgeScope(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='press-purge-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.site = self.base/'sites/example.com/public_html'
        for directory in ['wp-admin','wp-content','wp-includes']:
            (self.site/directory).mkdir(parents=True)
        for file in ['wp-load.php','wp-settings.php','wp-config.php']:
            (self.site/file).write_text('<?php /* inert */\n')
        (self.site/'wp-includes/version.php').write_text('<?php $wp_version="7.1";\n')
        self.context = self.base/'context.json'
        self.context.write_text(json.dumps({'multi':False,'network':1,'blog':1}))
        runner = self.base/'scope-runner.php'
        runner.write_text('''<?php
$c=json_decode(file_get_contents(getenv('TEST_CONTEXT')),true);
function is_multisite(){return $GLOBALS['c']['multi'];}
function get_current_blog_id(){return $GLOBALS['c']['blog'];}
function get_current_network_id(){return $GLOBALS['c']['network'];}
function get_site($id){
 if(!in_array($id,[1,2,3,4],true))return null;
 return (object)['blog_id'=>$id,'site_id'=>$id===3?2:1,'deleted'=>$id===4];
}
$args=array_slice($argv,2);require $argv[1];
''')
        bindir = self.base/'bin'
        bindir.mkdir()
        adapter = bindir/'wp'
        adapter.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
from pathlib import Path
args=[a for a in sys.argv[1:] if not (a.startswith('--path=') or a in ['--skip-plugins','--skip-themes','--skip-packages','--no-color'])]
base=Path(os.environ['TEST_BASE'])
with (base/'calls').open('a') as f:f.write(json.dumps(args)+'\\n')
if args[:2]==['core','is-installed']:sys.exit(0)
if args and args[0]=='plugin':
 if args[1]=='get':print('7.5-fixture')
 sys.exit(0)
if args and args[0]=='help':sys.exit(0)
if args and args[0]=='eval-file' and args[1].endswith('/litespeed-purge-scope.php'):
 count=base/'scope-count'; n=int(count.read_text())+1 if count.exists() else 1;count.write_text(str(n))
 if os.environ.get('TEST_SCOPE_FAIL')=='1':sys.exit(67)
 if n>1 and os.environ.get('TEST_SCOPE_CHANGE')=='1':
  ctx=json.loads(Path(os.environ['TEST_CONTEXT']).read_text());ctx['network']=2;Path(os.environ['TEST_CONTEXT']).write_text(json.dumps(ctx))
 sys.exit(subprocess.run(['php',str(base/'scope-runner.php'),*args[1:]],timeout=10).returncode)
if args and args[0]=='litespeed-purge':
 (base/'purged').write_text(json.dumps(args));print('Success: inert purge recorded.');sys.exit(0)
sys.exit(99)
''')
        adapter.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.base), PATH=str(bindir)+':/usr/local/bin:/usr/bin:/bin',
                        TEST_BASE=str(self.base), TEST_CONTEXT=str(self.context),
                        PRESSGARDEN_CONFIG_FILE=str(self.base/'absent'), PRESSGARDEN_SCAN_ROOT=str(self.base/'sites'),
                        PRESSGARDEN_STATE_DIR=str(self.base/'state'), PRESSGARDEN_CACHE_DIR=str(self.base/'cache'),
                        PRESSGARDEN_INTERACTIVE='0', PRESSGARDEN_NOCOLOR='1', PRESSGARDEN_PROGRESS='0')

    def multi(self):
        self.context.write_text(json.dumps({'multi':True,'network':1,'blog':1}))

    def run_cli(self,*args):
        return subprocess.run(['bash',str(ROOT/'pressgarden'),*args],env=self.env,
                              capture_output=True,text=True,timeout=25)

    def refused(self,r):
        self.assertEqual(r.returncode,2,r.stdout+r.stderr)
        self.assertFalse((self.base/'purged').exists())

    def test_single_site_cache_clear(self):
        r=self.run_cli('cache','clear','example.com')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn('scope single:1',r.stdout)
        self.assertEqual(json.loads((self.base/'purged').read_text()),['litespeed-purge','all'])

    def test_multisite_cache_clear_refuses_implicit_network(self):
        self.multi();r=self.run_cli('cache','clear','example.com');self.refused(r)
        self.assertIn('--network',r.stdout+r.stderr)

    def test_explicit_network_purge(self):
        self.multi();r=self.run_cli('litespeed','purge','all','--network','--target','example.com')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn('scope network:1',r.stdout)
        self.assertEqual((self.base/'scope-count').read_text(),'2')
        self.assertEqual(json.loads((self.base/'purged').read_text()),['litespeed-purge','all'])

    def test_active_blog_purge(self):
        self.multi();r=self.run_cli('litespeed','purge','blog','2','--target','example.com')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(json.loads((self.base/'purged').read_text()),['litespeed-purge','blog','2'])

    def test_absent_blog_refused(self):
        self.multi();self.refused(self.run_cli('litespeed','purge','blog','99','--target','example.com'))

    def test_cross_network_blog_refused(self):
        self.multi();self.refused(self.run_cli('litespeed','purge','blog','3','--target','example.com'))

    def test_inactive_blog_refused(self):
        self.multi();self.refused(self.run_cli('litespeed','purge','blog','4','--target','example.com'))

    def test_single_site_foreign_blog_refused(self):
        self.refused(self.run_cli('litespeed','purge','blog','2','--target','example.com'))

    def test_scope_probe_failure_refused(self):
        self.env['TEST_SCOPE_FAIL']='1';self.refused(self.run_cli('cache','clear','example.com'))

    def test_scope_change_under_writer_lock_refused(self):
        self.multi();self.env['TEST_SCOPE_CHANGE']='1'
        r=self.run_cli('litespeed','purge','all','--network','--target','example.com');self.refused(r)
        self.assertIn('scope changed',r.stdout)

    def test_invalid_id_refused_before_wp(self):
        self.refused(self.run_cli('litespeed','purge','blog','0','--target','example.com'))
        self.assertFalse((self.base/'calls').exists())

    def test_duplicate_network_flag_refused(self):
        self.refused(self.run_cli('litespeed','purge','all','--network','--network','--target','example.com'))
        self.assertFalse((self.base/'calls').exists())

if __name__=='__main__':unittest.main(verbosity=2)
