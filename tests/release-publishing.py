#!/usr/bin/env python3
"""Offline release tests: no GitHub token, network, or production site required."""
import copy
import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('publisher', ROOT / '.github/scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = 'a' * 40
REPO = 'marketania/PressGarden'
REQUIRED = ['.github/workflows/ci.yml', '.github/workflows/db-quality.yml']


def run(path=REQUIRED[0], ident=1, **changes):
    row = dict(id=ident, path=path, name='CI', html_url='https://github.com/' + REPO + '/actions/runs/1',
               event='push', head_branch='main', head_sha=SHA, status='completed', conclusion='success',
               head_repository={'full_name': REPO})
    row.update(changes)
    return row


class FakeAPI:
    def __init__(self, bad_asset=False):
        self.calls = []
        self.bad_asset = bad_asset

    def request(self, path, method='GET', data=None, filename=None):
        self.calls.append((path, method, data, filename))
        if filename:
            return dict(state='uploaded', size=len(data) + int(self.bad_asset),
                        digest='sha256:' + hashlib.sha256(data).hexdigest())
        if method == 'POST':
            return {'id': 19}
        if method == 'PATCH':
            return {'draft': False, 'html_url': 'https://github.com/' + REPO + '/releases/tag/v0.1.0'}
        raise AssertionError('Unexpected request')


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.event = {'repository': {'full_name': REPO}, 'workflow_run': run()}
        self.runs = [run(), run(REQUIRED[1], 2)]

    def test_only_trusted_successful_main_push_is_eligible(self):
        self.assertTrue(release.eligible(self.event, REPO, 'PressGarden', SHA))
        for key, value in [('event', 'pull_request'), ('head_branch', 'feature'),
                           ('head_sha', 'b' * 40), ('conclusion', 'failure'),
                           ('status', 'in_progress'), ('head_repository', {'full_name': 'fork/PressGarden'})]:
            event = copy.deepcopy(self.event)
            event['workflow_run'][key] = value
            self.assertFalse(release.eligible(event, REPO, 'PressGarden', SHA), key)
        self.assertFalse(release.eligible(self.event, 'fork/PressGarden', 'PressGarden', SHA))
        self.assertFalse(release.eligible(self.event, REPO, 'PressHarden', SHA))
        self.assertFalse(release.eligible({}, REPO, 'PressGarden', SHA))

    def test_all_required_workflows_pass_on_exact_commit(self):
        self.assertEqual(len(release.passing_runs(self.runs, REQUIRED, SHA, REPO)), 2)
        self.assertIsNone(release.passing_runs(self.runs[:1], REQUIRED, SHA, REPO))
        self.assertIsNone(release.passing_runs([], REQUIRED, SHA, REPO))

    def test_old_commit_pr_fork_and_non_main_cannot_substitute(self):
        for changes in [dict(head_sha='b' * 40), dict(event='pull_request'), dict(head_branch='feature'),
                        dict(head_repository={'full_name': 'fork/PressGarden'})]:
            self.assertIsNone(release.passing_runs([self.runs[0], run(REQUIRED[1], 2, **changes)], REQUIRED, SHA, REPO))

    def test_no_failed_pending_skipped_cancelled_or_missing_conclusions(self):
        for status, conclusion in [('completed', 'failure'), ('in_progress', None), ('queued', None),
                                   ('completed', 'skipped'), ('completed', 'cancelled'), ('completed', None)]:
            rows = [self.runs[0], run(REQUIRED[1], 2, status=status, conclusion=conclusion)]
            self.assertIsNone(release.passing_runs(rows, REQUIRED, SHA, REPO))

    def test_newer_failure_overrules_old_success(self):
        rows = self.runs + [run(REQUIRED[1], 3, conclusion='failure')]
        self.assertIsNone(release.passing_runs(rows, REQUIRED, SHA, REPO))
        rows.append(run(REQUIRED[1], 4))
        evidence = release.passing_runs(rows, REQUIRED, SHA, REPO)
        self.assertEqual(evidence[1]['id'], 4)

    def test_draft_upload_then_publish(self):
        api = FakeAPI()
        with contextlib.redirect_stdout(io.StringIO()):
            release.publish(api, 'v0.1.0', 'PressGarden', SHA, {'file.tar.gz': b'benign'}, 'Notes')
        self.assertTrue(api.calls[0][2]['draft'])
        self.assertEqual(api.calls[0][2]['target_commitish'], SHA)
        self.assertEqual(api.calls[-1][1], 'PATCH')
        self.assertFalse(api.calls[-1][2]['draft'])

    def test_failed_asset_remains_unpublished(self):
        api = FakeAPI(bad_asset=True)
        with self.assertRaises(release.ReleaseError):
            release.publish(api, 'v0.1.0', 'PressGarden', SHA, {'file.tar.gz': b'benign'}, 'Notes')
        self.assertFalse(any(method == 'PATCH' for _, method, _, _ in api.calls))

    def test_no_credential_redirects(self):
        with self.assertRaises(release.ReleaseError):
            release.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://not-github.invalid')

    def test_source_archive_excludes_untracked_data_and_checksums_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / 'docs/releases').mkdir(parents=True)
            (path / 'docs/releases/0.1.0.md').write_text('Initial standalone release\n')
            (path / 'PRODUCT').write_text('PressGarden\n')
            (path / 'VERSION').write_text('0.1.0\n')
            for args in [('init', '-q'), ('add', '.'), ('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')]:
                subprocess.run(['git', '-C', str(path), *args], check=True, capture_output=True)
            (path / 'untracked-private-secret').write_text('must never ship')
            destination = path / 'output'; destination.mkdir()
            previous = Path.cwd()
            try:
                os.chdir(path)
                sha = release.git('rev-parse', 'HEAD')
                assets, _ = release.build_assets('PressGarden', '0.1.0', sha, [], destination)
            finally:
                os.chdir(previous)
            with tarfile.open(fileobj=io.BytesIO(gzip.decompress(assets['PressGarden-0.1.0.tar.gz']))) as archive:
                self.assertFalse(any('secret' in n or '/.git/' in n for n in archive.getnames()))
                self.assertIn('PressGarden-0.1.0/PRODUCT', archive.getnames())
            for line in assets['SHA256SUMS'].decode().splitlines():
                digest, name = line.split('  ', 1)
                self.assertEqual(digest, hashlib.sha256(assets[name]).hexdigest())
            self.assertEqual(json.loads(assets['SOURCE.json'])['commit'], sha)

    def test_main_stale_head_existing_release_tag_and_pending_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / '.github').mkdir()
            (path / 'PRODUCT').write_text('PressGarden')
            (path / 'VERSION').write_text('0.1.0')
            (path / '.github/release-policy.json').write_text(json.dumps({'required_workflows': REQUIRED}))
            (path / 'event.json').write_text(json.dumps(self.event))
            previous = Path.cwd()
            try:
                os.chdir(path)
                for scenario in ('stale', 'published', 'draft', 'tag-conflict', 'pending', 'ready'):
                    def request(endpoint, method='GET', **kwargs):
                        self.assertEqual(method, 'GET')
                        if endpoint == '/git/ref/heads/main':
                            return {'object': {'sha': 'b' * 40 if scenario == 'stale' else SHA}}
                        if endpoint.startswith('/releases/tags/'):
                            return {'draft': scenario == 'draft'} if scenario in ('published', 'draft') else None
                        if endpoint.startswith('/git/ref/tags/'):
                            return {'object': {'sha': 'b' * 40, 'type': 'commit'}} if scenario == 'tag-conflict' else None
                        if endpoint.startswith('/actions/runs?'):
                            return {'workflow_runs': self.runs[:1] if scenario == 'pending' else self.runs}
                        raise AssertionError(endpoint)
                    with patch.dict(os.environ, {'GITHUB_REPOSITORY': REPO, 'GITHUB_EVENT_NAME': 'workflow_run',
                          'GITHUB_EVENT_PATH': str(path / 'event.json'), 'GH_TOKEN': 'inert-fixture'}), \
                         patch.object(release, 'git', return_value=SHA), patch.object(release, 'GitHub') as client, \
                         patch.object(release, 'build_assets', return_value=({}, 'Notes')) as build, \
                         patch.object(release, 'publish') as publish, contextlib.redirect_stdout(io.StringIO()):
                        client.return_value.request.side_effect = request
                        if scenario in ('draft', 'tag-conflict'):
                            with self.assertRaises(release.ReleaseError):
                                release.main()
                        else:
                            release.main()
                        self.assertEqual(publish.call_count, int(scenario == 'ready'))
                        self.assertEqual(build.call_count, int(scenario == 'ready'))
            finally:
                os.chdir(previous)

    def test_policy_covers_all_existing_ci_and_trigger_names(self):
        policy = json.loads((ROOT / '.github/release-policy.json').read_text())['required_workflows']
        workflows = sorted(str(p.relative_to(ROOT)) for p in (ROOT / '.github/workflows').glob('*.yml') if p.name != 'release.yml')
        self.assertEqual(sorted(policy), workflows)
        text = (ROOT / '.github/workflows/release.yml').read_text()
        names = json.loads(re.search(r'    workflows: (\[.*\])', text).group(1))
        expected = [re.search(r'^name: (.*)$', (ROOT / p).read_text(), re.M).group(1).strip() for p in policy]
        self.assertEqual(sorted(names), sorted(expected))
        self.assertIn("head_repository.full_name == github.repository", text)
        self.assertIn("event == 'push'", text)
        self.assertNotIn('pull_request_target', text)
        version = (ROOT / 'VERSION').read_text().strip()
        self.assertTrue((ROOT / ('docs/releases/' + version + '.md')).is_file())


if __name__ == '__main__':
    unittest.main(verbosity=2)
