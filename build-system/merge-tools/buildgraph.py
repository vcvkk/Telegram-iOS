#!/usr/bin/env python3
"""Which directories bazel actually reaches when it builds the app.

Several directories in this tree carry Swift that nothing depends on:
`submodules/LegacyDataImport` is referenced only by its own BUILD file, and
`exteraGram/Playground` is a separate `ios_application` that `Make.py build`
never touches. Both have been stale for releases, and a checker that reports
them fails on findings CI can never hit — which makes it useless as a gate.

The graph here is deliberately coarse: one node per BUILD file directory, one
edge per `//path:target` (or `:local`) label in that file. Reachability from the
app's directory is then a plain BFS. That over-approximates — a directory is
"reachable" if *any* target in it is — which is the safe direction: it keeps
files in the report rather than dropping them.

    from buildgraph import reachable_directories
    live = reachable_directories(REPO_ROOT)
    if not in_reachable(rel_path, live): ...
"""

import os
import re
from collections import deque
from glob import glob

# Every label form that appears in this tree's BUILD files.
LABEL_RE = re.compile(r'"(//[\w./+-]+(?::[\w./+-]+)?|:[\w./+-]+)"')
DEFAULT_ROOTS = ["Telegram"]


def _read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def build_directories(repo_root):
    """dir -> set of dirs it references, for every BUILD file in the tree."""
    edges = {}
    for build_path in glob(os.path.join(repo_root, "**", "BUILD"), recursive=True):
        rel_dir = os.path.relpath(os.path.dirname(build_path), repo_root)
        if rel_dir.startswith("bazel-") or "/bazel-" in rel_dir:
            continue
        targets = edges.setdefault(rel_dir, set())
        for match in LABEL_RE.finditer(_read(build_path)):
            label = match.group(1)
            if label.startswith(":"):
                continue  # same directory
            target_dir = label[2:].split(":")[0].rstrip("/")
            if target_dir:
                targets.add(target_dir)
    return edges


def reachable_directories(repo_root, roots=None):
    """Directories reachable from the app target's directory, inclusive."""
    edges = build_directories(repo_root)
    seen = set()
    queue = deque(roots or DEFAULT_ROOTS)
    while queue:
        current = queue.popleft()
        if current in seen:
            continue
        seen.add(current)
        for neighbour in edges.get(current, ()):
            if neighbour not in seen:
                queue.append(neighbour)
    return seen


def in_reachable(rel_path, reachable):
    """True when a repo-relative source path lives under a reachable directory."""
    directory = os.path.dirname(rel_path)
    while directory:
        if directory in reachable:
            return True
        directory = os.path.dirname(directory)
    return "" in reachable


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    live = reachable_directories(root)
    print(f"{len(live)} directories reachable from {', '.join(DEFAULT_ROOTS)}")
    for name in sorted(live):
        print(f"  {name}")
