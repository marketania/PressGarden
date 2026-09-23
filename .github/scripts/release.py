#!/usr/bin/env python3
"""Publish tracked source only after exact-main CI passes; never deploy a website."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request


class ReleaseError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ReleaseError("Unexpected API redirect; credentials not forwarded")


class GitHub:
    def __init__(self, repository, token):
        self.repository = repository
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, path, method="GET", data=None, filename=None):
        host = "https://uploads.github.com" if filename else "https://api.github.com"
        headers = {"Authorization": "Bearer " + self.token,
                   "Accept": "application/vnd.github+json", "User-Agent": "Press-family-release"}
        if filename:
            body = data
            headers["Content-Type"] = "application/octet-stream"
        else:
            body = None if data is None else json.dumps(data).encode()
            if body is not None:
                headers["Content-Type"] = "application/json"
        request = urllib.request.Request(host + "/repos/" + self.repository + path,
                                         data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404 and method == "GET":
                return None
            raise ReleaseError("GitHub API request failed (HTTP %s); no credentials logged" % error.code) from None


def eligible(event, repository, product, sha):
    run = event.get("workflow_run", {})
    return (repository == "marketania/" + product
            and event.get("repository", {}).get("full_name") == repository
            and run.get("head_repository", {}).get("full_name") == repository
            and run.get("event") == "push" and run.get("head_branch") == "main"
            and run.get("head_sha") == sha and re.fullmatch(r"[0-9a-f]{40}", sha) is not None
            and run.get("status") == "completed" and run.get("conclusion") == "success")


def passing_runs(runs, required, sha, repository):
    """Use the newest run for every required path; never substitute PR/older CI."""
    latest = {}
    for run in runs:
        path = run.get("path", "").split("@")[0]
        if (path not in required or run.get("head_sha") != sha
                or run.get("event") != "push" or run.get("head_branch") != "main"
                or run.get("head_repository", {}).get("full_name") != repository):
            continue
        if path not in latest or run["id"] > latest[path]["id"]:
            latest[path] = run
    if set(latest) != set(required):
        return None
    if any(r.get("status") != "completed" or r.get("conclusion") != "success" for r in latest.values()):
        return None
    return [{k: latest[path].get(k) for k in ("id", "name", "path", "html_url", "head_sha", "conclusion")}
            for path in sorted(latest)]


def git(*args):
    return subprocess.check_output(["git", *args]).decode().strip()


def build_assets(product, version, sha, evidence, destination):
    notes = Path("docs/releases/" + version + ".md").read_text()
    if not notes.strip():
        raise ReleaseError("Version-specific release notes are required")
    tar = subprocess.check_output(["git", "archive", "--format=tar", "--prefix=" + product + "-" + version + "/", sha])
    assets = {product + "-" + version + ".tar.gz": gzip.compress(tar, mtime=0),
              "RELEASE_NOTES.md": notes.encode(),
              "SOURCE.json": (json.dumps({"product": product, "version": version,
                  "repository": "marketania/" + product, "commit": sha,
                  "tree": git("rev-parse", sha + "^{tree}"), "checks": evidence}, indent=2) + "\n").encode()}
    assets["SHA256SUMS"] = "".join(hashlib.sha256(data).hexdigest() + "  " + name + "\n"
                                     for name, data in sorted(assets.items())).encode()
    for name, data in assets.items():
        (destination / name).write_bytes(data)
    return assets, notes


def publish(api, tag, product, sha, assets, notes):
    release = api.request("/releases", "POST", {"tag_name": tag, "target_commitish": sha,
                          "name": product + " " + tag, "body": notes + "\n\nVerified source commit: `" + sha + "`.\n",
                          "draft": True, "prerelease": False})
    if not release or not isinstance(release.get("id"), int):
        raise ReleaseError("Release creation did not return an ID")
    release_id = release["id"]
    for name, data in assets.items():
        asset = api.request("/releases/%s/assets?name=%s" % (release_id, urllib.parse.quote(name, safe="")),
                            "POST", data, filename=name)
        if not asset or asset.get("state") != "uploaded" or asset.get("size") != len(data):
            raise ReleaseError("Asset upload incomplete; release remains a draft")
        digest = asset.get("digest")
        if digest and digest != "sha256:" + hashlib.sha256(data).hexdigest():
            raise ReleaseError("Asset digest mismatch; release remains a draft")
    result = api.request("/releases/%s" % release_id, "PATCH", {"draft": False, "make_latest": "true"})
    if not result or result.get("draft") is not False:
        raise ReleaseError("Publication not confirmed; inspect the draft release")
    print("Published " + result.get("html_url", tag))


def main():
    product = Path("PRODUCT").read_text().strip()
    version = Path("VERSION").read_text().strip()
    if product not in ("PressWarden", "PressHarden", "PressGarden") or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ReleaseError("Unsupported product/version")
    repository = os.environ["GITHUB_REPOSITORY"]
    sha = git("rev-parse", "HEAD")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    if os.environ.get("GITHUB_EVENT_NAME") != "workflow_run" or not eligible(event, repository, product, sha):
        raise ReleaseError("Only completed successful same-repository main push CI can publish")
    api = GitHub(repository, os.environ["GH_TOKEN"])
    head = api.request("/git/ref/heads/main")
    if not head or head.get("object", {}).get("sha") != sha:
        print("No publication: this is no longer the main tip")
        return
    tag = "v" + version
    existing = api.request("/releases/tags/" + tag)
    if existing:
        if existing.get("draft"):
            raise ReleaseError("A draft for this version already exists; inspect it before retrying")
        print("Version already published; existing release/tag/assets left unchanged")
        return
    tag_ref = api.request("/git/ref/tags/" + tag)
    if tag_ref and (tag_ref.get("object", {}).get("type") != "commit" or tag_ref.get("object", {}).get("sha") != sha):
        raise ReleaseError("Existing tag does not match the candidate; it will not be moved")
    required = json.loads(Path(".github/release-policy.json").read_text())["required_workflows"]
    if not required or len(required) != len(set(required)) or ".github/workflows/ci.yml" not in required:
        raise ReleaseError("Invalid release policy")
    runs = []
    for page in range(1, 11):
        response = api.request("/actions/runs?" + urllib.parse.urlencode({"head_sha": sha, "event": "push",
                                "branch": "main", "per_page": 100, "page": page}))
        if not response:
            raise ReleaseError("CI evidence unavailable")
        batch = response.get("workflow_runs", [])
        runs.extend(batch)
        if len(batch) < 100:
            break
    else:
        raise ReleaseError("CI listing incomplete; publication withheld")
    evidence = passing_runs(runs, required, sha, repository)
    if evidence is None:
        print("No publication: required exact-commit main checks are missing, pending or unsuccessful")
        return
    # Check current main a second time before creating any release or tag.
    if api.request("/git/ref/heads/main").get("object", {}).get("sha") != sha:
        print("No publication: main advanced during verification")
        return
    with tempfile.TemporaryDirectory(prefix="press-release-") as directory:
        assets, notes = build_assets(product, version, sha, evidence, Path(directory))
        publish(api, tag, product, sha, assets, notes)


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # No raw API bodies, headers, credentials or client data are printed.
        print("Release withheld: " + (str(error) if isinstance(error, ReleaseError) else type(error).__name__))
        raise SystemExit(2)
