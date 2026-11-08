#!/usr/bin/env python3
"""Advance one registered binary kernel input to a newer vendor branch head."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.error import URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


REPOSITORY = "raspberrypi/firmware"
BOARDS = {"8": "-v8+", "_2712": "-v8-16k+"}


def registered_series():
    return json.loads(subprocess.check_output([
        "nix", "eval", "--json", "--no-write-lock-file",
        "path:.#lib.rpiBinaryKernelSeries",
    ], text=True))


def github_api(path, raw=False):
    headers = {
        "Accept": "application/vnd.github.raw+json" if raw else "application/vnd.github+json",
        "User-Agent": "raspberry-pi-nix-binary-updater",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(f"https://api.github.com/repos/{REPOSITORY}/{path}", headers=headers)
    with urlopen(request, timeout=30) as response:
        body = response.read().decode("utf-8")
    return body if raw else json.loads(body)


def checked_rev(rev):
    if not isinstance(rev, str) or not re.fullmatch(r"[0-9a-f]{40}", rev):
        raise ValueError("expected an immutable 40-character firmware commit SHA")
    return rev


def locked_input(lock, input_name):
    node = lock["nodes"][lock["root"]]["inputs"][input_name]
    if not isinstance(node, str):
        raise ValueError(f"{input_name}: expected a direct root input in flake.lock")
    locked = lock["nodes"][node]["locked"]
    if (locked.get("type"), locked.get("owner"), locked.get("repo")) != (
        "github", "raspberrypi", "firmware"
    ):
        raise ValueError(f"{input_name}: locked input is not raspberrypi/firmware")
    return node, checked_rev(locked["rev"])


def series_numbers(version):
    match = re.fullmatch(r"v([0-9]+)_([0-9]+)", version)
    if match is None:
        raise ValueError(f"invalid registered series: {version}")
    return tuple(map(int, match.groups()))


def uname_release(board, text):
    release = re.match(r"Linux version ([0-9]+)\.([0-9]+)\.([0-9]+)(\S*) ", text)
    if release is None:
        raise ValueError(f"missing or malformed uname_string{board}")
    return tuple(map(int, release.groups()[:3])), release.group(4)


def firmware_metadata(rev, version):
    checked_rev(rev)
    metadata = {"8": github_api(f"contents/extra/uname_string8?ref={rev}", raw=True)}
    number, _ = uname_release("8", metadata["8"])
    # Old vendor branches may predate Pi 5; unrelated series need no second file.
    if number[:2] == series_numbers(version):
        metadata["_2712"] = github_api(f"contents/extra/uname_string_2712?ref={rev}", raw=True)
    return metadata


def bundle_version(version, metadata):
    """Return a matching numeric release, ignore other series, reject broken bundles."""
    series = series_numbers(version)
    first, suffix = uname_release("8", metadata.get("8", ""))
    if first[:2] != series:
        return None
    second, second_suffix = uname_release("_2712", metadata.get("_2712", ""))
    if suffix != BOARDS["8"] or second_suffix != BOARDS["_2712"]:
        raise ValueError(f"{version}: board metadata has the wrong release suffix")
    if first != second:
        raise ValueError(f"{version}: board kernel versions disagree")
    return first


def select_candidate(version, current_metadata, candidates):
    """Choose the highest strictly newer patch; candidates are (branch, SHA, metadata)."""
    current = bundle_version(version, current_metadata)
    if current is None:
        raise ValueError(f"locked input does not contain {version}")
    best = None
    best_version = current
    for branch, rev, metadata in candidates:
        candidate_version = bundle_version(version, metadata)
        if candidate_version is not None and candidate_version > best_version:
            checked_rev(rev)
            best = (branch, rev, metadata)
            best_version = candidate_version
    return best


def branch_candidates(version):
    candidates = []
    page = 1
    while True:
        branches = github_api(f"branches?per_page=100&page={page}")
        if not isinstance(branches, list):
            raise ValueError("firmware branches API did not return a list")
        for branch in branches:
            rev = checked_rev(branch["commit"]["sha"])
            candidates.append((branch["name"], rev, firmware_metadata(rev, version)))
        if len(branches) < 100:
            return candidates
        page += 1


def update_input(input_name, rev, old_lock):
    flake_path = Path("flake.nix")
    lock_path = Path("flake.lock")
    original_flake = flake_path.read_text()
    original_lock = lock_path.read_text()
    pattern = (
        rf'(?m)(^[ \t]*{re.escape(input_name)}[ \t]*=[ \t]*\{{[^{{}}]*?\burl[ \t]*=[ \t]*")'
        r'github:raspberrypi/firmware/[^"\n]+("[ \t]*;)'
    )
    updated, count = re.subn(pattern, lambda match: f'{match[1]}github:{REPOSITORY}/{rev}{match[2]}', original_flake)
    if count != 1:
        raise ValueError(f"expected exactly one firmware URL declaration for {input_name}, found {count}")
    flake_path.write_text(updated)
    try:
        subprocess.run(["nix", "flake", "update", input_name], check=True)
        new_lock = json.loads(lock_path.read_text())
        old_node, _ = locked_input(old_lock, input_name)
        new_node, new_rev = locked_input(new_lock, input_name)
        if new_rev != rev or old_node != new_node:
            raise ValueError("targeted lock update did not retain the selected firmware revision/input node")
        old_rest = json.loads(json.dumps(old_lock))
        new_rest = json.loads(json.dumps(new_lock))
        del old_rest["nodes"][old_node]
        del new_rest["nodes"][new_node]
        if old_rest != new_rest:
            raise ValueError("targeted lock update changed unrelated inputs")
    except BaseException:
        flake_path.write_text(original_flake)
        lock_path.write_text(original_lock)
        raise


def write_outputs(values):
    output = "".join(f"{name}={value}\n" for name, value in values.items())
    print(output, end="")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list-series", action="store_true")
    parser.add_argument("--check-only", action="store_true", help="discover candidates without changing flake.nix or flake.lock")
    parser.add_argument("version", nargs="?")
    parser.add_argument("summary_file", nargs="?", default="binary-kernel-update-summary.md")
    args = parser.parse_args()
    series = registered_series()
    if args.list_series:
        if args.version or args.check_only:
            parser.error("--list-series cannot be combined with a version or --check-only")
        print(json.dumps([entry["version"] for entry in series], separators=(",", ":")))
        return
    selected = [entry for entry in series if entry["version"] == args.version]
    if len(selected) != 1:
        parser.error("provide exactly one registered binary kernel series")
    input_name = selected[0]["input"]
    lock = json.loads(Path("flake.lock").read_text())
    _, old_rev = locked_input(lock, input_name)
    current_metadata = firmware_metadata(old_rev, args.version)
    candidates = branch_candidates(args.version)
    candidate = select_candidate(args.version, current_metadata, candidates)
    new_rev = candidate[1] if candidate else old_rev
    if candidate and not args.check_only:
        update_input(input_name, new_rev, lock)
    if candidate:
        outcome = "Candidate found; check-only mode left inputs unchanged." if args.check_only else "Updated the declared input URL and targeted lock entry."
    else:
        outcome = "Skipped: no vendor branch head contains a strictly newer patch for this series; inputs unchanged."
    current_release = ".".join(map(str, bundle_version(args.version, current_metadata)))
    candidate_release = ".".join(map(str, bundle_version(args.version, candidate[2]))) if candidate else "none"
    summary = f"""## Raspberry Pi binary kernel {args.version} update

{outcome}

- Input: `{input_name}`
- Current firmware revision: `{old_rev}` (kernel `{current_release}`)
- Selected firmware revision: `{new_rev}` (candidate kernel `{candidate_release}`)
- Inspected vendor branch heads: {len(candidates)}
"""
    if candidate:
        branch = candidate[0]
        summary += f"- Selected vendor branch: [{branch}](https://github.com/{REPOSITORY}/tree/{quote(branch, safe='')})\n"
        summary += f"- Compare: https://github.com/{REPOSITORY}/compare/{old_rev}...{new_rev}\n"
    summary += """
### Validation and limits

Selection reads both board uname metadata files at immutable firmware commits,
requires matching series, numeric patch versions and board suffixes, and never downgrades.
Upstream check runs/statuses were not queried; this is not an upstream checked-good claim.
Publication requires the workflow's four behavior checks and native x86_64 packaging
builds of both binary board packages. This updater does not run those gates.
Native ARM initrd evaluation and real hardware boot validation remain manual.
"""
    Path(args.summary_file).write_text(summary)
    write_outputs({
        "changed": str(bool(candidate) and not args.check_only).lower(),
        "candidate_available": str(bool(candidate)).lower(),
        "version": args.version,
        "input": input_name,
        "old_rev": old_rev,
        "new_rev": new_rev,
        "short_rev": new_rev[:12],
    })


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, URLError, subprocess.CalledProcessError) as error:
        print(f"binary kernel update failed: {error}", file=sys.stderr)
        sys.exit(1)
