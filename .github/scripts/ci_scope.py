#!/usr/bin/env python3
"""Classify cumulative PR changes offline; uncertainty always keeps full checks."""
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


def documentation_path(path):
    if not path or any(ord(c) < 32 for c in path) or "\\" in path:
        return False
    parts = PurePosixPath(path)
    if parts.is_absolute() or ".." in parts.parts:
        return False
    if "/" not in path and path.endswith(".md"):
        return True
    if path in (".github/PULL_REQUEST_TEMPLATE.md", "intel/README.md", "integrations/README.md"):
        return True
    if path.startswith("docs/"):
        return path.endswith(".md") or (
            path.startswith("docs/assets/")
            and parts.suffix.lower() in (".png", ".jpg", ".jpeg", ".gif", ".webp")
        )
    return False


def full_checks(event_name, event, repo="."):
    # Trusted main pushes remain full runs for exact-commit release evidence.
    # Manual/unknown events, new roots, missing history and empty diffs also run full.
    if event_name != "pull_request":
        return True
    try:
        base = event["pull_request"]["base"]["sha"]
        if not isinstance(base, str) or re.fullmatch(r"[0-9a-f]{40}", base) is None:
            return True
        common = subprocess.check_output(
            ["git", "merge-base", base, "HEAD"], cwd=repo, stderr=subprocess.DEVNULL, timeout=30
        ).decode().strip()
        if re.fullmatch(r"[0-9a-f]{40}", common) is None:
            return True
        paths = subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", common, "HEAD", "--"],
            cwd=repo, stderr=subprocess.DEVNULL, timeout=30,
        ).decode("utf-8").split("\0")
        paths = [p for p in paths if p]
        return not paths or any(not documentation_path(p) for p in paths)
    except (KeyError, TypeError, ValueError, UnicodeError, OSError, subprocess.SubprocessError):
        return True


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    except (KeyError, OSError, ValueError):
        event = {}
    full = full_checks(os.environ.get("GITHUB_EVENT_NAME", ""), event)
    value = "true" if full else "false"
    print("CI scope: " + ("full validation" if full else "documentation-only pull request"))
    # Only a constant boolean is emitted; never interpolate changed filenames/event data.
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write("full=" + value + "\n")


if __name__ == "__main__":
    main()
