#!/usr/bin/env python3
"""Incomplete new CLI distributions fail before install or code replacement."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CLIHelpers(unittest.TestCase):
    def test_required_referenced_helpers(self):
        with tempfile.TemporaryDirectory(prefix='garden-distribution-') as folder:
            base = Path(folder)
            source = base / 'candidate'
            shutil.copytree(ROOT, source, ignore=shutil.ignore_patterns('.git', '__pycache__', 'var'))
            env = dict(os.environ, HOME=str(base), PRESSGARDEN_INSTALL_SOURCE=str(source),
                       PRESSGARDEN_INSTALL_PREFIX=str(base / 'install'),
                       PRESSGARDEN_CONFIG_FILE=str(base / 'absent'))
            for helper in ['lib/cli.sh', 'checks/cleanup-all.sh', 'lib/cleanup-summary.php']:
                with self.subTest(helper=helper):
                    (source / helper).unlink()
                    install = subprocess.run(['bash', str(ROOT / 'install.sh')], env=env,
                                             text=True, capture_output=True, timeout=20)
                    self.assertEqual(install.returncode, 2, install.stdout + install.stderr)
                    self.assertIn(helper, install.stdout + install.stderr)
                    self.assertFalse((base / 'install').exists())
                    update = subprocess.run(['bash', '-c', '. "$1/lib/update.sh"; _pg_update_validate_source "$2"',
                                             '_', str(ROOT), str(source)], env=env,
                                            text=True, capture_output=True, timeout=20)
                    self.assertEqual(update.returncode, 2, update.stdout + update.stderr)
                    self.assertIn(helper, update.stdout + update.stderr)
                    shutil.copy2(ROOT / helper, source / helper)


if __name__ == '__main__':
    unittest.main(verbosity=2)
