#!/usr/bin/env python3
"""Distribution contracts; no external packages, network or website access."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
product=(root/'PRODUCT').read_text().strip();program=product.lower()
errors=[]
for required in [program,'VERSION','PRODUCT','README.md','LICENSE','install.sh','uninstall.sh','config/config.example','lib/_lib.sh','lib/update.sh','lib/target-path.php','tests/run.sh']:
 if not (root/required).is_file():errors.append('Missing '+required)
for file in root.rglob('*.md'):
 if '.git' in file.parts or 'var' in file.parts:continue
 for target in re.findall(r'\]\(([^\s)]+)',file.read_text()):
  if '://' in target or target.startswith(('#','mailto:')):continue
  if not (file.parent/target.split('#')[0]).exists():errors.append(f'{file.relative_to(root)}: broken link {target}')
for file in (root/'.github/workflows').glob('*.yml'):
 for path in re.findall(r'\b(?:bash|php|python3)\s+(tests/[A-Za-z0-9_./-]+)',file.read_text()):
  if not (root/path).is_file():errors.append(f'{file.name}: missing test {path}')
if errors:raise SystemExit('\n'.join(errors))
print(f'{product} distribution identity, lifecycle assets, internal links and workflow test references PASS')
