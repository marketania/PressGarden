#!/usr/bin/env python3
"""Inert native database adapter and real PHP identity contract; no network/SQL writes."""
from pathlib import Path
import json, os, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parents[1]
class DatabaseIdentity(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='press-db-identity-');self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name);self.site=self.base/'fleet/example.test/public_html'
        for name in ('wp-admin','wp-content','wp-includes'):(self.site/name).mkdir(parents=True)
        for name in ('wp-load.php','wp-settings.php','wp-config.php'):(self.site/name).write_text('<?php // inert\n')
        (self.site/'wp-includes/version.php').write_text('<?php $wp_version="7.1";\n')
        bindir=self.base/'bin';bindir.mkdir()
        self.env=dict(os.environ,PATH=str(bindir)+':/usr/local/bin:/usr/bin:/bin',HOME=str(self.base),
                      PRESSGARDEN_SCAN_ROOT=str(self.base/'fleet'),PRESSGARDEN_CONFIG_FILE=str(self.base/'absent'),
                      PRESSGARDEN_STATE_DIR=str(self.base/'state'),PRESSGARDEN_CACHE_DIR=str(self.base/'cache'),
                      PRESSGARDEN_INTERACTIVE='0',PRESSGARDEN_PROGRESS='0',PRESSGARDEN_NOCOLOR='1',
                      TEST_BASE=str(self.base),TEST_MODE='good')
        (bindir/'wp').write_text(r'''#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
b=Path(os.environ['TEST_BASE']);m=os.environ['TEST_MODE'];a=[x for x in sys.argv[1:] if not x.startswith('--')]
actual=b/'actual';identity=actual.read_text() if actual.exists() else 'a'*64
if a[0]=='eval-file':
 action=a[2]
 if action=='identity':
  counter=b/'count';n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
  if m=='identity-failure':sys.exit(7)
  if m=='before-backup' and n>=2:identity='b'*64
  print(identity)
  if m=='before-action' and n>=3:actual.write_text('b'*64)
  sys.exit(0)
 if action=='plan':print('wp_options,wp_posts');sys.exit(0)
 if action in ('optimize','repair','cleanup'):
  expected=a[8] if len(a)>8 else ''
  if ':' in expected and expected.split(':',1)[1]!=identity:sys.exit(2)
  (b/'mutated').write_text(identity);sys.exit(0)
 sys.exit(0)
if a[:2]==['db','export']:
 (b/'exported').write_text(identity)
 if m=='backup-failure':sys.exit(41)
 Path(a[2]).write_text('-- inert SQL export fixture; never imported\n')
 if m=='after-backup':actual.write_text('b'*64)
 sys.exit(0)
sys.exit(99)
''')
        (bindir/'wp').chmod(0o755)

    def run_cli(self,mode):
        self.env['TEST_MODE']=mode
        return subprocess.run(['bash',str(ROOT/'pressgarden'),'db','optimize','example.test'],env=self.env,text=True,capture_output=True,timeout=20)
    def refused(self,mode):
        r=self.run_cli(mode);self.assertEqual(r.returncode,2,r.stdout+r.stderr)
        self.assertFalse((self.base/'mutated').exists(), 'mutation reached a different/unverified DB')
        return r
    def test_same_identity_is_backed_up_and_mutated(self):
        r=self.run_cli('good');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual((self.base/'mutated').read_text(),(self.base/'exported').read_text())
    def test_changed_connection_before_backup_refuses_export(self):
        self.refused('before-backup');self.assertFalse((self.base/'exported').exists())
    def test_database_changes_during_export_without_changing_prefix(self):
        self.refused('after-backup');self.assertTrue((self.base/'exported').exists())
    def test_final_runtime_guard_binds_execution_identity(self):self.refused('before-action')
    def test_identity_failure_prevents_export_and_mutation(self):
        self.refused('identity-failure');self.assertFalse((self.base/'exported').exists())
    def test_backup_failure_still_prevents_mutation(self):self.refused('backup-failure')
    def php(self,body):
        script=self.base/'fixture.php'
        script.write_text('''<?php
define('PG_DATABASE_TEST',true);define('ARRAY_A','ARRAY_A');
define('DB_NAME','fixture_db');define('DB_HOST','127.0.0.1:3306');define('DB_USER','fixture_user');
require $argv[1];
class IdentityDB {
 public $prefix='wp_', $last_error='', $database='fixture_db', $server='fixture_host', $port='3306';
 function get_results($sql,$mode){
  if(strpos($sql,'SELECT DATABASE()')!==0)throw new RuntimeException('Unexpected fixture query');
  return [['database_name'=>$this->database,'server_hostname'=>$this->server,'server_port'=>$this->port]];
 }
}
$wpdb=new IdentityDB();
'''+body)
        return subprocess.run(['php',str(script),str(ROOT/'lib/database.php')],capture_output=True,text=True,timeout=10)
    def test_fingerprint_changes_with_server_port_and_prefix(self):
        r=self.php('''$first=pg_db_identity();if(!preg_match('/^[a-f0-9]{64}$/D',$first))exit(3);
foreach(['server','port','prefix'] as $property){$old=$wpdb->$property;$wpdb->$property.='2';if(pg_db_identity()===$first)exit(4);$wpdb->$property=$old;}
echo "identity variance verified";''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('fixture_db',r.stdout);self.assertNotIn('fixture_user',r.stdout)
    def test_connected_database_must_match_export_configuration(self):
        r=self.php("if(!function_exists('pg_db_identity'))exit(8);$wpdb->database='unrelated_db';try{pg_db_identity();exit(9);}catch(Throwable $e){exit(strpos($e->getMessage(),'differs from configured export')!==false?0:7);}")
        self.assertEqual(r.returncode,0,r.stderr)
    def test_execution_guard_rejects_stale_identity_and_missing_gate(self):
        r=self.php('''$csv='wp_options,wp_posts';$expected=hash('sha256',$csv).':'.pg_db_identity();
pg_db_guard($csv,$expected,true);$wpdb->server='another_host';
try{pg_db_guard($csv,$expected,true);exit(9);}catch(Throwable $e){}
try{pg_db_guard($csv,'',true);exit(10);}catch(Throwable $e){}
echo "guard verified";''')
        self.assertEqual(r.returncode,0,r.stderr)
if __name__=='__main__':unittest.main(verbosity=2)
