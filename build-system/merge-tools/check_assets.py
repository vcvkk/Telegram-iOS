#!/usr/bin/env python3
"""Find asset catalogs whose files and Contents.json disagree.

`AssetCatalogCompile` treats a file sitting in an imageset that no entry in
Contents.json references as an error ("has an unassigned child"), and it is the
very last thing the release build does — so this costs a full release round to
discover, and `validate.yml` never sees it at all, because a debug compile-only
run does not build the app bundle.

The 12.9.2 bump produced nine of these at once. `merge3.py` copies upstream
asset files in, which is right when the fork simply carries upstream's artwork,
and wrong when the fork deliberately replaced it: the Watch app icon is one
`exteraGram.png` in this fork, so upstream's eleven files landed beside it
unreferenced.

Two shapes are reported:
  orphan   a file present on disk that no Contents.json entry names
  missing  an entry naming something that is not there

`missing` on directory-valued entries (a `.complicationset` referring to nested
imagesets) is not real — those are checked and skipped.

Usage:
    check_assets.py [--paths DIR ...]

Exits non-zero when anything is found.
"""

import argparse
import json
import os
import sys

DEFAULT_ROOTS = ["submodules", "Telegram", "exteraGram"]

# Contents.json keys whose entries can carry a "filename".
ENTRY_KEYS = (
    "images",
    "icons",
    "assets",
    "filters",
    "layers",
    "properties",
    "colors",
    "data",
)


def referenced_names(data):
    names = set()
    for key in ENTRY_KEYS:
        for entry in data.get(key, []) or []:
            if isinstance(entry, dict) and entry.get("filename"):
                names.add(entry["filename"])
    return names


def check_directory(dirpath, filenames):
    manifest = os.path.join(dirpath, "Contents.json")
    try:
        with open(manifest, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as error:
        return [f"unreadable Contents.json: {error}"]

    referenced = referenced_names(data)
    on_disk = {name for name in filenames if name != "Contents.json"}

    problems = []
    for name in sorted(on_disk - referenced):
        problems.append(f"orphan file (no Contents.json entry): {name}")
    for name in sorted(referenced - on_disk):
        # A nested catalog (e.g. a .complicationset naming imagesets) is a
        # directory, not a file, and is present even though it is not in
        # `filenames`.
        if not os.path.isdir(os.path.join(dirpath, name)):
            problems.append(f"missing file named by Contents.json: {name}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paths", nargs="*", default=DEFAULT_ROOTS)
    args = parser.parse_args()

    total = 0
    checked = 0
    for root in args.paths:
        for dirpath, _, filenames in os.walk(root):
            if "Contents.json" not in filenames:
                continue
            checked += 1
            problems = check_directory(dirpath, filenames)
            if problems:
                print(f"\n  {dirpath}")
                for problem in problems:
                    print(f"      {problem}")
                total += len(problems)

    if total:
        print(f"\nFAIL: {total} problem(s) in {checked} asset directories.")
        print(
            "Decide per directory: if the fork deliberately replaced the "
            "artwork, delete the upstream files merge3.py copied in; if it "
            "just carries upstream's, take upstream's Contents.json and file "
            "set wholesale."
        )
        return 1

    print(f"OK: {checked} asset directories consistent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
