#!/usr/bin/env python3
"""Prepare a git repository for the secret scan (CONTRACT AC-22).

Runs on the host. The content scan itself is gitleaks (tests/ac/22-no-secrets.sh,
rules in .gitleaks.toml); this script does what gitleaks does not:

  - tracked files that .gitignore would ignore (added before, or forced)
  - tracked file names of key, token and secret material
  - any binary or non-UTF-8 blob (DER keys, keystores; gitleaks skips binary
    files, and this repository has none)
  - .gitignore covers the paths where key material would land
  - writes every blob reachable from any ref, as raw content, to
    <export dir>/<blob sha>/<path>, for gitleaks to scan as plain files. Reading
    blobs rather than `git log -p` means diff settings such as .gitattributes
    "-diff" cannot hide anything, and deleted files are still scanned.

Prints one "finding=<kind> <where>" line per problem, then "findings=<count>"
and "blobs=<count>". It fails closed: a repository it cannot read is a finding,
not a clean result.

Usage: python3 -I secret-scan.py <repo dir> <empty export dir>
"""
import os
import re
import subprocess
import sys

repo, export = sys.argv[1], os.path.realpath(sys.argv[2])
findings = []


def finding(kind, where):
    findings.append(f"{kind} {where}")


def git(*args, binary=False):
    out = subprocess.run(["git", "-C", repo, *args], capture_output=True, check=False)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.decode(errors="replace").strip())
    return out.stdout if binary else out.stdout.decode(errors="replace")


SECRET_NAME = re.compile(
    r"(^|/)([^/]*\.(key|pem|jwk|p12|pfx|der|jks|keystore)|[^/]*_key|[^/]*join_token[^/]*"
    r"|keys\.json|agent-data\.json|[^/]*\.sqlite3[^/]*|secrets/.*)$"
)


def export_blob(sha, path, data):
    where = f"{path or '?'} (blob {sha[:12]})"
    if b"\0" in data[:8192]:
        finding("binary blob committed:", where)
        return
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        finding("non-UTF-8 blob committed:", where)
        return
    # Keep the file name: some gitleaks rules look at it. Git paths cannot
    # contain "..", but check anyway that the file lands inside the export dir.
    dest = os.path.realpath(os.path.join(export, sha, path or "unnamed"))
    if not dest.startswith(os.path.join(export, sha) + os.sep):
        finding("blob path outside the export dir:", where)
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as f:
        f.write(data)


try:
    git("rev-parse", "--verify", "-q", "HEAD")
except RuntimeError as e:
    print(f"finding={repo} is not a git repository with commits; nothing could be scanned ({e})")
    print("findings=1")
    sys.exit(0)

for f in git("ls-files", "-ci", "--exclude-standard").splitlines():
    finding("tracked but ignored:", f)
for f in git("ls-files").splitlines():
    if SECRET_NAME.search(f):
        finding("secret-like file name tracked:", f)

seen = set()
blobs = 0
for line in git("rev-list", "--all", "--objects").splitlines():
    sha, _, path = line.partition(" ")
    if sha in seen:
        continue
    seen.add(sha)
    if git("cat-file", "-t", sha).strip() != "blob":
        continue
    blobs += 1
    export_blob(sha, path, git("cat-file", "blob", sha, binary=True))

for p in ["x.key", "x.pem", "x.jwk", "a/ssh_user_ca_key", "a/intermediate_ca_key", "secrets/x",
          "a/secrets/x", "join_token", "agent-token/join_token", "keys.json", "agent-data.json",
          "datastore.sqlite3"]:
    r = subprocess.run(["git", "-C", repo, "check-ignore", "-q", "--no-index", p], check=False)
    if r.returncode != 0:
        finding(".gitignore does not cover", p)

for f in findings:
    print(f"finding={f}")
print(f"findings={len(findings)}")
print(f"blobs={blobs}")
