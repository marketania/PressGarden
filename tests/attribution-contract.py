#!/usr/bin/env python3
"""Protect original credits, exact link markup, license, provenance and artwork."""
from pathlib import Path
import hashlib
import json
import unittest
ROOT=Path(__file__).resolve().parents[1]
BASE=json.loads((ROOT/'tests/fixtures/attribution-baseline.json').read_text())

def protected_readme(text):
    for line in BASE['readme_protected_lines']:
        if line not in text: return False
        prefix=text[:text.index(line)].lower()
        # Original credits and links must not be hidden in collapsed markup.
        if prefix.count('<details')>prefix.count('</details>'): return False
    return True

class AttributionContract(unittest.TestCase):
    def test_original_credits_and_destinations_visible(self):
        self.assertTrue(protected_readme((ROOT/'README.md').read_text()))
    def test_original_files_and_artwork_unchanged(self):
        for name,digest in BASE['files'].items():
            path=ROOT/name
            self.assertFalse(path.is_symlink(),name)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),digest,name)
    def test_removal_redirection_or_collapsing_is_rejected(self):
        original=(ROOT/'README.md').read_text()
        for line in BASE['readme_protected_lines']:
            self.assertFalse(protected_readme(original.replace(line,'',1)))
        self.assertFalse(protected_readme(original.replace('github.com/marketania','example.invalid/marketania')))
        self.assertFalse(protected_readme('<details>\n'+original+'\n</details>'))
if __name__=='__main__': unittest.main(verbosity=2)
