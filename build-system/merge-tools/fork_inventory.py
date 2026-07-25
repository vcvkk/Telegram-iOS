#!/usr/bin/env python3
"""Verify that fork-specific declarations survived an upstream merge.

The 12.8 bump copied upstream files over ours, which silently deleted
declarations that upstream had removed but the fork still uses (all of
PeersNearby, EmojiStatusSelectionControllerMode, revealHiddenPanels, ...). Each
loss surfaced as a confusing compile error one CI round at a time.

This checks the registry in fork_registry.json plus the fork's EG module set and
hook-marker counts, so the same class of loss is caught in seconds.

Usage:
    fork_inventory.py                    # report, exit 1 if anything is missing
    fork_inventory.py --check            # same (explicit)
    fork_inventory.py --update-baseline  # record current hook counts as floors
"""

import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REGISTRY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "fork_registry.json")


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def count_marker(marker):
    """Count occurrences of a literal marker across tracked source files."""
    try:
        result = subprocess.run(
            ["git", "grep", "-F", "-c", marker, "--",
             "*.swift", "*.m", "*.mm", "*.h", "BUILD"],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=120,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    total = 0
    for line in result.stdout.splitlines():
        if ":" in line:
            try:
                total += int(line.rsplit(":", 1)[1])
            except ValueError:
                pass
    return total


def check_feature(entry):
    """Return (ok, detail) for one registry entry."""
    path = os.path.join(REPO_ROOT, entry["path"])
    pattern = entry.get("pattern")

    if not os.path.exists(path):
        return False, f"missing path: {entry['path']}"

    if os.path.isdir(path):
        if not pattern:
            return True, "directory present"
        regex = re.compile(pattern)
        for root, _dirs, files in os.walk(path):
            for name in files:
                if name.endswith((".swift", ".m", ".mm", ".h")) or name == "BUILD":
                    if regex.search(read(os.path.join(root, name))):
                        return True, "pattern found"
        return False, f"pattern /{pattern}/ not found under {entry['path']}"

    if not pattern:
        return True, "file present"
    if re.search(pattern, read(path)):
        return True, "pattern found"
    return False, f"pattern /{pattern}/ not found in {entry['path']}"


def eg_modules():
    eg_root = os.path.join(REPO_ROOT, "exteraGram")
    if not os.path.isdir(eg_root):
        return []
    return sorted(
        name for name in os.listdir(eg_root)
        if os.path.isdir(os.path.join(eg_root, name))
        and os.path.exists(os.path.join(eg_root, name, "BUILD"))
    )


def main():
    registry = json.loads(read(REGISTRY_PATH))
    update_baseline = "--update-baseline" in sys.argv

    failures = []

    print("=== fork-specific declarations ===")
    for entry in registry["features"]:
        ok, detail = check_feature(entry)
        print(f"  [{'ok ' if ok else 'MISS'}] {entry['name']}")
        if not ok:
            failures.append(f"{entry['name']}: {detail}")

    print("\n=== exteraGram modules ===")
    modules = eg_modules()
    print(f"  {len(modules)} module(s): {', '.join(modules) if modules else '(none)'}")
    if not modules:
        failures.append("no exteraGram modules with a BUILD file found")

    print("\n=== fork hook markers ===")
    floors = registry.get("min_hook_counts", {})
    counts = {}
    for marker in registry["hook_markers"]:
        count = count_marker(marker)
        counts[marker] = count
        floor = floors.get(marker, 0)
        if count is None:
            print(f"  [skip] {marker}: git grep unavailable")
            continue
        status = "ok " if count >= floor else "DROP"
        print(f"  [{status}] {marker}: {count} (floor {floor})")
        if count < floor:
            failures.append(
                f"hook marker '{marker}' dropped to {count}, floor is {floor}"
            )

    if update_baseline:
        registry.setdefault("min_hook_counts", {})
        comment = registry["min_hook_counts"].get("_comment")
        # 5% headroom: ordinary refactors move these counts a little, while a
        # merge that wipes fork hooks drops them by tens of percent.
        registry["min_hook_counts"] = {
            marker: int(value * 0.95)
            for marker, value in counts.items() if value is not None
        }
        if comment:
            registry["min_hook_counts"]["_comment"] = comment
        with open(REGISTRY_PATH, "w") as handle:
            json.dump(registry, handle, indent=2)
            handle.write("\n")
        print(f"\nBaseline updated in {os.path.relpath(REGISTRY_PATH, REPO_ROOT)}")
        return 0

    if failures:
        print(f"\nFAIL: {len(failures)} problem(s):")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("\nOK: all fork-specific declarations present.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
