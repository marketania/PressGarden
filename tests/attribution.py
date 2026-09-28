#!/usr/bin/env python3
"""Preserve the pre-refinement attribution, backlinks, provenance and artwork."""
from collections import Counter
from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASELINE = json.loads((ROOT / 'tests/fixtures/attribution.json').read_text())

class Attribution(unittest.TestCase):
    def test_immutable_attribution_and_artwork(self):
        for name, digest in BASELINE['files'].items():
            with self.subTest(path=name):
                path = ROOT / name
                self.assertFalse(path.is_symlink())
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)

    def test_protected_text_and_links(self):
        for name, protected in BASELINE['lines'].items():
            with self.subTest(path=name):
                text = (ROOT / name).read_text()
                self.assertFalse(Counter(protected) - Counter(text.splitlines()))

    def test_visible_readme_brand_and_family_links(self):
        text = (ROOT / 'README.md').read_text()
        self.assertLess(text.index('docs/assets/press-tool-family.webp'), 200)
        self.assertLess(text.index('## Other Press tools'), text.index('## Install'))
        # Do not hide original attribution in collapsed sections.
        self.assertNotIn('<details', text.lower())
        for name in ['PressWarden', 'PressGarden', 'PressHarden']:
            if name != BASELINE['product']:
                self.assertIn('https://github.com/marketania/' + name, text)

if __name__ == '__main__':
    unittest.main(verbosity=2)
