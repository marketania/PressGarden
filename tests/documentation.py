#!/usr/bin/env python3
"""Read-only documentation contracts. Never execute commands copied from docs.

Checks this repository's entrypoint/action examples, concrete environment names,
and relative Markdown file links. It is not a shell parser, external-link checker,
or validator for every option/hosting-specific effect. Historical migration and
release documents may describe former commands and are exempt from CLI checks.
"""
from pathlib import Path
import re
import tempfile
import unittest
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
RETIRED = {
    'presswarden': {'lock', 'unlock', 'lock-status', 'file-mods', 'wp-settings',
                   'auto-update', 'auto-updates', 'cleanup', 'litespeed',
                   'litespeed-db', 'litespeed-database', 'database'},
    'pressgarden': {'database'},
    'pressharden': set(),
}
ACTIONS = {
    'pressgarden': {
        'db': {'status', 'check', 'repair', 'optimize', 'cleanup'},
        'cache': {'status', 'clear', 'enable', 'disable'},
        'litespeed-db': {'status', 'optimize', 'optimize-all', 'optimize_all'},
        'litespeed': {'status', 'help', 'option', 'purge', 'presets', 'preset',
                      'image', 'online', 'debug', 'crawler', 'database', 'db'},
    },
    'pressharden': {'php': {'status', 'inspect', 'set'}},
    'presswarden': {'inspect': {'php', 'js', 'db', 'runtime', 'help'}},
}


def document_paths(root):
    # Do not inspect private portable state, backups, config, or website trees.
    paths = list(root.glob('*.md'))
    for folder in ['docs', 'intel', 'integrations', '.github']:
        paths += list((root / folder).rglob('*.md'))
    return sorted(set(paths))


def historical(path):
    return (path.name in {'MIGRATION.md', 'OWNERSHIP.md', 'PROVENANCE.md'}
            or path.name.startswith('CHANGELOG') or 'releases' in path.parts)


def dispatch_commands(source, program):
    # Top-level arms in all three dispatchers use exactly two-space indentation.
    # Fail if that convention changes rather than silently checking no examples.
    tail = source.split('case "$cmd" in', 1)[1]
    labels = re.findall(r'^  ([A-Za-z0-9_|-]+)\)', tail, re.M)
    commands = {item for label in labels for item in label.split('|')}
    if '"${1:-}" = config-new' in source:
        commands.add('config-new')  # intentionally handled before config loading
    assert {'help', 'sites', 'update', 'config'}.issubset(commands), 'Dispatcher layout changed'
    return commands - RETIRED[program]


def cli_errors(text, program, commands):
    errors = []
    # Spaces/tabs only: never consume the next line as a command argument.
    pattern = r'(?<![\w/-])(?:\./)?' + re.escape(program) + r'[ \t]+([a-z][a-z0-9_-]*(?:[|/][a-z][a-z0-9_-]*)*)'
    for match in re.finditer(pattern, text):
        verbs = re.split(r'[|/]', match[1])
        line = text.count('\n', 0, match.start()) + 1
        for verb in verbs:
            if verb not in commands:
                errors.append('{}: unsupported entrypoint {}'.format(line, verb))
        if len(verbs) != 1 or verbs[0] not in ACTIONS.get(program, {}):
            continue
        action = re.match(r'[ \t]+([a-z][a-z0-9_-]*(?:[|/][a-z][a-z0-9_-]*)*)(?=[ \t`\n]|$)', text[match.end():])
        if action:
            for part in re.split(r'[|/]', action[1]):
                if part not in ACTIONS[program][verbs[0]]:
                    errors.append('{}: unsupported {} action {}'.format(line, verbs[0], part))
    return errors


def without_fences(text):
    lines = []
    fence = None
    for line in text.splitlines():
        found = re.match(r'^\s*(`{3,}|~{3,})', line)
        if found and fence is None:
            fence = (found[1][0], len(found[1]))
            lines.append('')
        elif found and fence and found[1][0] == fence[0] and len(found[1]) >= fence[1]:
            fence = None
            lines.append('')
        else:
            lines.append(line if fence is None else '')
    return '\n'.join(lines)


def local_link_errors(root, path, text):
    text = without_fences(text)
    # Inline/image links and reference definitions used by this project's docs.
    dests = re.findall(r'!?\[[^\]\n]*\]\((<[^>\n]+>|[^\s)\n]+)(?:[ \t]+[\'\"][^\n]*?[\'\"])?\)', text)
    dests += re.findall(r'^\s*\[[^\]\n]+\]:[ \t]*(<[^>\n]+>|\S+)', text, re.M)
    errors = []
    for dest in dests:
        dest = dest.strip('<>')
        parsed = urlsplit(dest)
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        local = unquote(parsed.path)
        target = (root / local.lstrip('/') if local.startswith('/') else path.parent / local).resolve()
        try:
            target.relative_to(root.resolve())
        except ValueError:
            errors.append('link escapes repository: ' + dest)
            continue
        if not target.exists():
            errors.append('missing local link target: ' + dest)
    return errors


class DocumentationContracts(unittest.TestCase):
    def test_checker_rejects_old_commands(self):
        for program in RETIRED:
            commands = {'status', 'db', 'php', 'inspect', 'config-new'} - RETIRED[program]
            self.assertTrue(cli_errors(program + ' invented-action example.com', program, commands))
        self.assertTrue(cli_errors('pressgarden db all', 'pressgarden', {'db'}))
        self.assertTrue(cli_errors('./pressharden php optimize example.com', 'pressharden', {'php'}))
        self.assertFalse(cli_errors('pressgarden db check example.com', 'pressgarden', {'db'}))
        self.assertFalse(cli_errors('pressgarden db status|check [target]', 'pressgarden', {'db'}))

    def test_checker_finds_missing_links_without_executing_examples(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / 'README.md'
            (root / 'ok file.md').write_text('# OK\n')
            self.assertFalse(local_link_errors(root, path, '[ok](ok%20file.md)\n[web](https://example.invalid/missing)'))
            self.assertFalse(local_link_errors(root, path, '```bash\n[not a link](missing)\n```'))
            self.assertTrue(local_link_errors(root, path, '[bad](missing.md)'))
            self.assertTrue(local_link_errors(root, path, '[bad]: missing.md'))
            self.assertTrue(local_link_errors(root, path, '[bad](../outside.md)'))

    def test_historical_boundaries(self):
        for path in ['CHANGELOG.md', 'docs/CHANGELOG-1.x.md', 'docs/MIGRATION.md', 'docs/releases/0.1.0.md']:
            self.assertTrue(historical(Path(path)))
        self.assertFalse(historical(Path('docs/SITE-TARGETS.md')))

    def test_current_operator_examples(self):
        program = (ROOT / 'PRODUCT').read_text().strip().lower()
        commands = dispatch_commands((ROOT / program).read_text(), program)
        errors = []
        for path in document_paths(ROOT):
            if '.git' in path.parts or historical(path.relative_to(ROOT)):
                continue
            errors += ['{}:{}'.format(path.relative_to(ROOT), error)
                       for error in cli_errors(path.read_text(), program, commands)]
        self.assertEqual(errors, [], '\n'.join(errors))

    def test_concrete_environment_names(self):
        product = (ROOT / 'PRODUCT').read_text().strip()
        files = [ROOT / product.lower(), ROOT / 'install.sh', ROOT / 'uninstall.sh']
        files.append(ROOT / 'config/config.example')
        for folder in ['lib', 'checks', 'suites']:
            files += [p for p in (ROOT / folder).rglob('*')
                      if p.is_file() and p.suffix in {'.sh', '.php'}]
        corpus = '\n'.join(p.read_text(errors='replace') for p in files if p.is_file())
        test_corpus = '\n'.join(p.read_text(errors='replace')
                                for p in (ROOT / 'tests').rglob('*')
                                if p.is_file() and p.suffix in {'.py', '.sh'})
        errors = []
        for path in document_paths(ROOT):
            if '.git' in path.parts or historical(path.relative_to(ROOT)):
                continue
            for name in set(re.findall(r'\b' + product.upper() + r'_[A-Z0-9_]+\b', path.read_text())):
                if name not in (test_corpus if '_ALLOW_ISOLATED_' in name else corpus):
                    errors.append('{}: undocumented-in-code variable {}'.format(path.relative_to(ROOT), name))
        self.assertEqual(errors, [], '\n'.join(errors))

    def test_repository_local_markdown_links(self):
        errors = []
        for path in document_paths(ROOT):
            if '.git' not in path.parts:
                errors += ['{}: {}'.format(path.relative_to(ROOT), error)
                           for error in local_link_errors(ROOT, path, path.read_text())]
        self.assertEqual(errors, [], '\n'.join(errors))


if __name__ == '__main__':
    unittest.main(verbosity=2)
