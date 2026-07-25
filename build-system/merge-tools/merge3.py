#!/usr/bin/env python3
"""Per-file 3-way merge of an upstream version bump onto the fork.

Why this exists: the 12.8 bump was done by copying upstream files over ours
(commit 5a815eb8 has a single parent). That has no notion of "what upstream
changed" versus "what we changed", so it both clobbered fork edits and left
files behind at the previous version. The resulting mixed tree produced ~15 CI
rounds of signature-mismatch errors.

This reconstructs a real 3-way merge per file:

    BASE   upstream release we currently derive from  (e.g. release-12.8)
    OURS   the file in this working tree              (fork edits included)
    THEIRS upstream release we are bumping to         (e.g. release-12.9.2)

so `diff(BASE, THEIRS)` is the pure upstream delta and gets applied on top of
our edits, with real conflict markers where both sides touched the same lines.

Classification per path:
    clean          merged without conflict (written when --apply)
    conflict       needs manual resolution (written with markers when --apply)
    ours-only      exists only in our tree (fork-only file: left alone)
    theirs-new     new upstream file (copied when --apply)
    theirs-deleted upstream removed it; ours matches BASE -> safe to delete
    theirs-deleted-modified  upstream removed it but we changed it: review
    unchanged      upstream did not touch it between BASE and THEIRS
    stale          ours differs from BASE while upstream never changed the file
                   -> leftover from a previous incomplete bump; review

Usage:
    merge3.py --audit  --base /tmp/upstream/release-12.8 --theirs /tmp/upstream/release-12.9.2
    merge3.py --apply  --base ... --theirs ... --paths submodules/TelegramCore
    merge3.py --audit  --base ... --theirs ... --paths 'submodules/TelegramUI/**'
"""

import argparse
import fnmatch
import os
import shutil
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Paths we never merge: generated, vendored blobs, or fork-owned by definition.
SKIP_PREFIXES = (
    ".git/", "bazel-", "build-input/", "exteraGram/",
    "submodules/ffmpeg/Sources/FFMpeg/", "third-party/",
)
SKIP_SUFFIXES = (".png", ".jpg", ".jpeg", ".pdf", ".zip", ".tgs", ".mp4", ".mp3",
                 ".caf", ".ttf", ".otf", ".webp", ".ico", ".car", ".xcuserstate")

TEXT_SUFFIXES = (".swift", ".m", ".mm", ".h", ".c", ".cc", ".cpp", ".hpp",
                 "BUILD", ".bzl", ".json", ".yml", ".yaml", ".sh", ".py",
                 ".strings", ".plist", ".modulemap", ".entitlements", ".pbxproj")


def is_mergeable(rel_path):
    if any(rel_path.startswith(p) for p in SKIP_PREFIXES):
        return False
    if rel_path.endswith(SKIP_SUFFIXES):
        return False
    return rel_path.endswith(TEXT_SUFFIXES) or os.path.basename(rel_path) == "BUILD"


def list_files(root):
    """Relative paths of all files under root, excluding .git and bazel dirs."""
    found = set()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d for d in dirnames
            if d != ".git" and not d.startswith("bazel-")
        ]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            found.add(rel)
    return found


def read_bytes(path):
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError:
        return None


def same(path_a, path_b):
    return read_bytes(path_a) == read_bytes(path_b)


def classify(rel_path, base_root, theirs_root):
    """Decide what should happen to one path. Returns (state, detail)."""
    ours = os.path.join(REPO_ROOT, rel_path)
    base = os.path.join(base_root, rel_path)
    theirs = os.path.join(theirs_root, rel_path)

    has_ours = os.path.isfile(ours)
    has_base = os.path.isfile(base)
    has_theirs = os.path.isfile(theirs)

    if not has_ours and has_theirs:
        return ("theirs-new", "new upstream file")

    if has_ours and not has_theirs:
        if not has_base:
            return ("ours-only", "fork-only file")
        if same(ours, base):
            return ("theirs-deleted", "upstream deleted; ours unmodified")
        return ("theirs-deleted-modified", "upstream deleted but we modified it")

    if not (has_ours and has_theirs):
        return ("skip", "absent on both sides")

    if has_base and same(base, theirs):
        # Upstream did not touch this file in the bump.
        if same(ours, base):
            return ("unchanged", "identical everywhere")
        return ("stale", "ours differs from BASE though upstream never changed it")

    if not has_base:
        # No merge base: upstream added it earlier and we already carry a copy.
        if same(ours, theirs):
            return ("unchanged", "no base, ours already matches theirs")
        return ("conflict", "no merge base available")

    if same(ours, base):
        return ("clean", "fast-forward to upstream")

    return ("merge", "both sides changed")


def do_merge(rel_path, base_root, theirs_root, apply_changes):
    """Run git merge-file for a path that both sides changed."""
    ours = os.path.join(REPO_ROOT, rel_path)
    base = os.path.join(base_root, rel_path)
    theirs = os.path.join(theirs_root, rel_path)

    # git merge-file writes into the "current" file, so work on a copy.
    tmp = ours + ".merge3.tmp"
    shutil.copyfile(ours, tmp)
    try:
        result = subprocess.run(
            ["git", "merge-file", "-L", "ours", "-L", "base", "-L", "theirs",
             tmp, base, theirs],
            capture_output=True, text=True,
        )
        # Exit code: 0 = clean, >0 = number of conflicts, <0 = error.
        if result.returncode < 0:
            return ("error", result.stderr.strip()[:120])
        state = "clean" if result.returncode == 0 else "conflict"
        if apply_changes:
            shutil.move(tmp, ours)
        return (state, f"{result.returncode} conflict(s)" if result.returncode else "merged")
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True, help="BASE upstream tree")
    parser.add_argument("--theirs", required=True, help="THEIRS upstream tree")
    parser.add_argument("--paths", action="append", default=[],
                        help="limit to these path prefixes/globs (repeatable)")
    parser.add_argument("--audit", action="store_true", help="report only (default)")
    parser.add_argument("--apply", action="store_true", help="write merge results")
    parser.add_argument("--show", metavar="STATE",
                        help="list every path in STATE (e.g. stale, conflict)")
    args = parser.parse_args()

    if args.apply and args.audit:
        parser.error("choose either --audit or --apply")
    apply_changes = args.apply

    for root in (args.base, args.theirs):
        if not os.path.isdir(root):
            parser.error(f"not a directory: {root} (run fetch_upstream.sh first)")

    candidates = list_files(args.base) | list_files(args.theirs) | list_files(REPO_ROOT)
    candidates = {p for p in candidates if is_mergeable(p)}

    if args.paths:
        selected = set()
        for pattern in args.paths:
            for path in candidates:
                if path.startswith(pattern.rstrip("*").rstrip("/")) or \
                        fnmatch.fnmatch(path, pattern):
                    selected.add(path)
        candidates = selected

    buckets = {}
    for rel_path in sorted(candidates):
        state, detail = classify(rel_path, args.base, args.theirs)
        if state == "merge":
            state, detail = do_merge(rel_path, args.base, args.theirs, apply_changes)
        elif state == "clean" and apply_changes:
            shutil.copyfile(os.path.join(args.theirs, rel_path),
                            os.path.join(REPO_ROOT, rel_path))
        elif state == "theirs-new" and apply_changes:
            target = os.path.join(REPO_ROOT, rel_path)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(os.path.join(args.theirs, rel_path), target)
        buckets.setdefault(state, []).append((rel_path, detail))

    mode = "APPLY" if apply_changes else "AUDIT"
    scope = ", ".join(args.paths) if args.paths else "whole tree"
    print(f"=== merge3 {mode} · {scope} ===")
    print(f"    BASE   {args.base}")
    print(f"    THEIRS {args.theirs}\n")

    order = ["conflict", "stale", "theirs-deleted-modified", "theirs-new",
             "theirs-deleted", "clean", "ours-only", "unchanged", "error", "skip"]
    for state in order:
        if state in buckets:
            print(f"  {state:24} {len(buckets[state])}")
    for state in buckets:
        if state not in order:
            print(f"  {state:24} {len(buckets[state])}")

    if args.show:
        entries = buckets.get(args.show, [])
        print(f"\n=== {args.show} ({len(entries)}) ===")
        for rel_path, detail in entries:
            print(f"  {rel_path}    [{detail}]")

    needs_review = (len(buckets.get("conflict", [])) +
                    len(buckets.get("theirs-deleted-modified", [])) +
                    len(buckets.get("error", [])))
    if needs_review:
        print(f"\n{needs_review} path(s) need manual review"
              f" (rerun with --show conflict).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
