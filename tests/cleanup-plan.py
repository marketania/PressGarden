#!/usr/bin/env python3
"""Disposable filesystem cleanup: content coverage, previews and stale plans."""
from pathlib import Path
import hashlib
import json
import os
import pty
import fcntl
import termios
import select
import subprocess
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
class CleanupPlan(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='press-cleanup-plan-');self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name);self.site=self.base/'fleet/example.test/public_html'
        for name in ['wp-admin','wp-content','wp-includes']:(self.site/name).mkdir(parents=True)
        for name in ['wp-load.php','wp-settings.php','wp-config.php']:(self.site/name).write_text('<?php // inert\n')
        (self.site/'wp-includes/version.php').write_text('<?php $wp_version="7.1";\n')
        self.state=self.base/'state'
        self.env={'PATH':'/usr/local/bin:/usr/bin:/bin','HOME':str(self.base),'PRESSGARDEN_SCAN_ROOT':str(self.base/'fleet'),
                  'PRESSGARDEN_CONFIG_FILE':str(self.base/'absent'),'PRESSGARDEN_STATE_DIR':str(self.state),
                  'PRESSGARDEN_CACHE_DIR':str(self.base/'cache'),'PRESSGARDEN_INTERACTIVE':'0',
                  'PRESSGARDEN_NOCOLOR':'1','PRESSGARDEN_PROGRESS':'0'}
    def old(self,name,data=b'ordinary metadata'):
        path=self.site/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        os.utime(path,(946684800,946684800));return path
    def cli(self,action='execute',*options):
        return subprocess.run(['bash',str(ROOT/'pressgarden'),'cleanup',action,'example.test',*options],env=self.env,text=True,capture_output=True,timeout=15)
    def test_marker_after_old_prefix_is_preserved(self):
        p=self.old('.DS_Store',b'A'*70000+b'<?php /* inert evidence */')
        r=self.cli();self.assertEqual(r.returncode,2,r.stdout+r.stderr);self.assertTrue(p.exists())
    def test_marker_split_across_stream_blocks_is_preserved(self):
        p=self.old('._resource',b'A'*65534+b'<?php /* not executed */')
        r=self.cli();self.assertEqual(r.returncode,2,r.stdout+r.stderr);self.assertTrue(p.exists())
    def test_ide_settings_are_not_generated_cache(self):
        p=self.old('.vscode/settings.json',b'{"editor.tabSize": 4}')
        r=self.cli('execute','--development');self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertTrue(p.exists())
    def test_project_configuration_is_not_disposable(self):
        p=self.old('.editorconfig',b'root = true\n');q=self.old('phpunit.xml',b'<phpunit/>')
        r=self.cli('execute','--development');self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertTrue(p.exists());self.assertTrue(q.exists())
    def test_backup_and_evidence_directories_are_boundaries(self):
        paths=[self.old(d+'/.DS_Store') for d in ['backups','quarantine','evidence','wflogs']]
        r=self.cli();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        for p in paths:self.assertTrue(p.exists(),str(p))
    def test_real_copy_and_manifest_before_delete(self):
        p=self.old('.DS_Store');before=p.read_bytes();r=self.cli();self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertFalse(p.exists())
        manifests=list(self.state.glob('backups/file-cleanup/*/manifest.json'));self.assertEqual(len(manifests),1)
        m=json.loads(manifests[0].read_text());self.assertEqual(m['status'],'COMPLETED')
        self.assertEqual((manifests[0].parent/m['files'][0]['backup']).read_bytes(),before)
    def test_preview_has_no_target_mutation(self):
        p=self.old('.DS_Store');r=self.cli('preview');self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertTrue(p.exists())
        self.assertFalse((self.state/'backups/file-cleanup').exists())
    def test_new_metadata_is_not_deleted(self):
        p=self.old('.DS_Store');os.utime(p,None);r=self.cli();self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertTrue(p.exists())
    def test_backup_scope_failure_prevents_delete(self):
        p=self.old('.DS_Store');self.env['PRESSGARDEN_STATE_DIR']=str(self.site/'bad-state')
        r=self.cli();self.assertEqual(r.returncode,2,r.stdout+r.stderr);self.assertTrue(p.exists())
    def stale(self,change):
        p=self.old('folder/.DS_Store')
        script=r'''require $argv[1];$site=$argv[2];$state=$argv[3];$change=$argv[4];
[$items,$review]=pg_cleanup_scan($site,30,false,false,[$site]);
$p=$items[0]['path'];
if($change==='mtime')touch($p,946684801);
if($change==='mode')chmod($p,0600);
if($change==='contents')file_put_contents($p,'different metadata');
if($change==='nested'){mkdir(dirname($p).'/wp-admin');file_put_contents(dirname($p).'/wp-load.php','<?php');file_put_contents(dirname($p).'/wp-settings.php','<?php');}
try{pg_cleanup_execute_plan($state,$site,$items);exit(9);}catch(Throwable $e){echo $e->getMessage();exit(2);}
'''
        r=subprocess.run(['php','-r',script,str(ROOT/'lib/cleanup.php'),str(self.site),str(self.state),change],env=self.env,text=True,capture_output=True,timeout=15)
        self.assertEqual(r.returncode,2,r.stdout+r.stderr);self.assertNotIn('undefined function',r.stdout+r.stderr);self.assertTrue(p.exists())
        self.assertNotIn('COMPLETED',r.stdout+r.stderr)
    def test_touched_candidate_invalidates_plan(self):self.stale('mtime')
    def test_permission_change_invalidates_plan(self):self.stale('mode')
    def test_content_change_invalidates_plan(self):self.stale('contents')
    def test_new_nested_installation_invalidates_plan(self):self.stale('nested')
    def test_candidate_preview_precedes_noninteractive_refusal(self):
        p=self.old('.DS_Store');self.env['PRESSGARDEN_INTERACTIVE']='1'
        r=self.cli();self.assertEqual(r.returncode,1,r.stdout+r.stderr);self.assertTrue(p.exists())
        self.assertIn('CANDIDATE',r.stdout);self.assertNotIn('Files removed:',r.stdout)
    def test_backup_directory_collision_prevents_deletion(self):
        p=self.old('.DS_Store');self.state.mkdir(mode=0o700)
        (self.state/'backups').write_text('not a backup directory')
        r=self.cli();self.assertEqual(r.returncode,2,r.stdout+r.stderr);self.assertTrue(p.exists())
    def test_real_terminal_confirmation_binds_preview_snapshot(self):
        p=self.old('.DS_Store');self.env['PRESSGARDEN_INTERACTIVE']='1'
        master,slave=pty.openpty()
        def session():
            os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0)
        process=subprocess.Popen(['bash',str(ROOT/'pressgarden'),'cleanup','execute','example.test'],env=self.env,
                                 stdin=slave,stdout=slave,stderr=slave,preexec_fn=session)
        os.close(slave);output=b''
        try:
            end=time.monotonic()+10
            while b'[y/N]' not in output and time.monotonic()<end:
                if select.select([master],[],[],0.2)[0]:output+=os.read(master,65536)
            self.assertIn(b'CANDIDATE',output);self.assertIn(b'[y/N]',output)
            os.utime(p,(946684801,946684801));os.write(master,b'y\n')
            while process.poll() is None and time.monotonic()<end:
                if select.select([master],[],[],0.2)[0]:
                    try:output+=os.read(master,65536)
                    except OSError:break
            self.assertEqual(process.wait(timeout=3),2,output.decode(errors='replace'))
            self.assertTrue(p.exists());self.assertFalse(list(self.state.glob('backups/file-cleanup/*')))
        finally:
            if process.poll() is None:process.kill();process.wait()
            os.close(master)
if __name__=='__main__':unittest.main(verbosity=2)
