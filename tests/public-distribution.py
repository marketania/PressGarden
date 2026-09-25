#!/usr/bin/env python3
"""Offline distribution integrity checks; no model calls or websites."""
from pathlib import Path
import hashlib
import json
import re
import unittest
ROOT=Path(__file__).resolve().parents[1]

class PublicDistribution(unittest.TestCase):
    def test_approved_artwork(self):
        asset=ROOT/'docs/assets/press-tool-family.webp'
        self.assertFalse(asset.is_symlink());data=asset.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(),'b233844db9fa3ba73b9478b3617ca3bcb080988cc2d081faa71523da8d2f4110')
        self.assertEqual(data[:4],b'RIFF');self.assertEqual(data[8:12],b'WEBP')
        self.assertEqual(int.from_bytes(data[4:8],'little')+8,len(data));self.assertLess(len(data),100000)

    def test_readme_references_local_logo(self):
        text=(ROOT/'README.md').read_text()
        match=re.search(r'<img\s+[^>]*src="docs/assets/press-tool-family.webp"[^>]*>',text)
        self.assertIsNotNone(match);self.assertIn('alt="PressWarden',match[0]);self.assertLess(match.start(),200)
        self.assertNotIn('data:image',text)

    def test_codex_project_scope(self):
        text=(ROOT/'.codex/config.toml').read_text()
        settings=dict(re.findall(r'^([a-z_]+)\s*=\s*"([^"]+)"\s*$',text,re.M))
        self.assertEqual(settings,{'model':'gpt-6-astra','model_reasoning_effort':'medium'})
        self.assertNotIn('[',text)

    def test_pinned_workflows_and_no_temporary_payload(self):
        for path in (ROOT/'.github/workflows').glob('*.yml'):
            self.assertFalse(path.name.startswith('audit-'),path.name)
            for ref in re.findall(r'\buses:\s*([^\s#]+)',path.read_text()):
                if not ref.startswith('./'):self.assertRegex(ref,r'^[^@]+@[0-9a-f]{40}$',str(path))
        self.assertFalse((ROOT/'.github/audit-brand').exists())
        self.assertFalse((ROOT/'.github/audit-staging').exists())
        self.assertTrue((ROOT/'.github/dependabot.yml').is_file())

    def test_supported_php_and_release_gates(self):
        ci=(ROOT/'.github/workflows/ci.yml').read_text()
        for series in ['8.2','8.3','8.4','8.5']:self.assertIn("'"+series+"'",ci)
        self.assertIn('php:7.4-cli',ci);self.assertIn('--severity=error',ci)
        for path in json.loads((ROOT/'.github/release-policy.json').read_text())['required_workflows']:
            self.assertTrue((ROOT/path).is_file(),path)
        self.assertIn('contents: read',ci);self.assertNotIn('contents: write',ci)

if __name__=='__main__':unittest.main(verbosity=2)
