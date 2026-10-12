#!/usr/bin/env python3
"""Offline CI scope regressions; inert local Git fixtures, no provider APIs."""
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ".github/scripts/ci_scope.py"
spec = importlib.util.spec_from_file_location("ci_scope", SCRIPT)
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.write("README.md", "Initial fixture\n")
        self.write("lib/helper.php", "<?php // inert fixture\n")
        self.commit()
        self.base = self.git("rev-parse", "HEAD").strip()
        self.event = {"pull_request": {"base": {"sha": self.base}}}

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.DEVNULL).decode()

    def write(self, path, text):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def commit(self):
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")

    def classify(self, name="pull_request", event=None):
        return scope.full_checks(name, self.event if event is None else event, self.repo)

    def test_documentation_allowlist_is_narrow(self):
        for path in ["AGENTS.md", "CLAUDE.md", "docs/HANDOFF.md", "docs/assets/logo.webp",
                     ".github/PULL_REQUEST_TEMPLATE.md", "intel/README.md", "integrations/README.md"]:
            self.assertTrue(scope.documentation_path(path), path)
        for path in ["lib/helper.md", "tests/fixture.md", "config/config.example", "VERSION", "PRODUCT",
                     "scripts/check.sh", ".github/scripts/ci_scope.py", ".github/workflows/ci.yml",
                     "docs/tool.php", "docs/assets/code.svg", "../README.md", "/README.md", "docs/x\n.md"]:
            self.assertFalse(scope.documentation_path(path), path)

    def test_docs_only_pr_skips_expensive_work(self):
        self.write("docs/decision.md", "Inert documentation fixture\n")
        self.commit()
        self.assertFalse(self.classify())

    def test_code_then_docs_still_requires_full_cumulative_checks(self):
        self.write("lib/helper.php", "<?php // changed inert fixture\n")
        self.commit()
        self.write("docs/decision.md", "Documentation after code\n")
        self.commit()
        self.assertTrue(self.classify())

    def test_workflow_and_ci_helpers_are_always_code_changes(self):
        for path in [".github/workflows/ci.yml", ".github/scripts/ci_scope.py", "tests/ci-scope.py"]:
            with self.subTest(path=path):
                self.write(path, "Inert fixture\n")
                self.commit()
                self.assertTrue(self.classify())

    def test_code_renamed_into_documentation_is_not_hidden(self):
        (self.repo / "docs").mkdir()
        self.git("mv", "lib/helper.php", "docs/helper.md")
        self.commit()
        self.assertTrue(self.classify())

    def test_deleted_code_requires_full_checks(self):
        (self.repo / "lib/helper.php").unlink()
        self.commit()
        self.assertTrue(self.classify())

    def test_deleted_documentation_can_skip_expensive_work(self):
        (self.repo / "README.md").unlink()
        self.commit()
        self.assertFalse(self.classify())

    def test_all_main_push_manual_and_unknown_events_keep_release_evidence(self):
        self.write("README.md", "Docs-only push fixture\n")
        self.commit()
        for event in ["push", "workflow_dispatch", "merge_group", "pull_request_target", ""]:
            self.assertTrue(self.classify(event), event)

    def test_empty_malformed_and_missing_history_fail_closed(self):
        self.assertTrue(self.classify())
        for event in [{}, [], {"pull_request": {"base": {"sha": "a" * 40}}},
                      {"pull_request": {"base": {"sha": "--help"}}}]:
            self.assertTrue(self.classify(event=event))

    def test_git_errors_fail_closed_without_diagnostics(self):
        with patch.object(scope.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertTrue(self.classify())

    def test_cli_emits_only_constant_boolean(self):
        self.write("docs/decision.md", "Inert documentation fixture\n")
        self.commit()
        event = self.repo / "event.json"
        event.write_text(json.dumps(self.event))
        output = self.repo / "output"
        env = dict(os.environ, GITHUB_EVENT_NAME="pull_request", GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output))
        result = subprocess.run([sys.executable, "-B", str(SCRIPT)], cwd=self.repo, env=env,
                                text=True, capture_output=True, check=True)
        self.assertEqual(output.read_text(), "full=false\n")
        self.assertEqual(result.stdout.strip(), "CI scope: documentation-only pull request")


class WorkflowGuards(unittest.TestCase):
    def test_registered_workflows_keep_checks_and_release_trigger_separate(self):
        policy = json.loads((ROOT / ".github/release-policy.json").read_text())
        for filename in policy["required_workflows"]:
            text = (ROOT / filename).read_text()
            self.assertNotIn("pull_request_target:", text)
            self.assertNotIn("paths-ignore:", text)
            self.assertNotIn("    paths:", text)
            self.assertIn("  push:\n    branches: [main]", text)
            self.assertIn("  pull_request:\n    branches: [main]", text)
            self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", text)
            self.assertIn("github.workflow", text)
            self.assertIn("github.run_id", text)
            self.assertIn("fetch-depth: 0", text)
            self.assertIn("full: ${{ steps.scope.outputs.full }}", text)
            self.assertIn("Classify cumulative pull request scope", text)
        release = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("  workflow_run:", release)
        self.assertIn("cancel-in-progress: false", release)
        self.assertIn("head_repository.full_name == github.repository", release)
        self.assertIn("event == 'push'", release)

    def test_matrix_checks_exist_for_docs_and_cancelled_runs_do_not_restart_work(self):
        text = (ROOT / ".github/workflows/ci.yml").read_text()
        matrix = text.split("  php-supported:\n", 1)[1].split("  php74:\n", 1)[0]
        self.assertIn("    if: ${{ !cancelled() }}", matrix)
        self.assertIn("name: PHP ${{ matrix.php }} contracts", matrix)
        self.assertIn("php: ['8.2', '8.3', '8.4', '8.5']", matrix)
        self.assertIn("Preserve documentation-only matrix check context", matrix)
        self.assertIn("success() && (needs.local.result != 'success'", matrix)
        for job in ("php74", "wordpress"):
            body = re.split(r"\n  [a-z0-9_-]+:\n", text.split("  " + job + ":\n", 1)[1], maxsplit=1)[0]
            self.assertIn("!cancelled()", body)
            self.assertIn("needs.local.outputs.full != 'false'", body)
        self.assertIn("failure() && steps.scope.outputs.full != 'false'", text)
        self.assertIn("retention-days: 1", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
