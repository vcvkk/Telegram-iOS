#!/usr/bin/env python3
"""An ordered item list must not be replaced with duplicate ids.

`OrderedItemListTable.replaceItems` asserts that every id it is given is
unique. Release builds compile the assert out and silently keep a dangling
index row; debug builds -- the ones anyone runs in the simulator -- crash.
The 12.9.2 tree crashed every debug launch about five seconds in because
`_internal_managedRecentlyUsedInlineBots` asks `contacts.getTopPeers` for two
categories at once (flags `1 << 2` and `1 << 17`) and a bot present in both
came back twice. No compiler, no CI run, and no other checker here can see
that: it depends on what the server returns.

What *is* visible is the shape. The ids written come from a nested loop over
server-side groupings (`for category in categories { for topPeer in ... }`),
and each grouping is unique on its own but nothing makes their union unique.
This checker finds every function that calls `replaceOrderedItemListItems`,
and reports it when the function builds its items inside two nested `for`
loops and never deduplicates -- no `Set`, no `.insert(`, no `seen`/`unique`
helper, no `Dictionary(uniqueKeysWithValues:` / `Dictionary(grouping:`.

It is deliberately narrow: a single loop over one server list is trusted,
because the server does not repeat an item inside one list. A clean run is
not proof, and a finding is worth a look rather than an automatic fix -- the
dedupe has to pick which duplicate wins (the inline-bot fix keeps the highest
rating by deduplicating after the sort).

    python3 build-system/merge-tools/check_ordered_list_ids.py
"""

import os
import re
import sys
from glob import glob

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCAN_ROOTS = ["submodules/TelegramCore", "exteraGram"]

FUNC_RE = re.compile(r"\bfunc\s+\w+[^{]*\{")
REPLACE_RE = re.compile(r"\breplaceOrderedItemListItems\s*\(")
FOR_RE = re.compile(r"\bfor\s+(?:case\s+)?[^{]+?\s+in\s+[^{]+\{")
DEDUPE_RE = re.compile(
    r"Set<|Set\(|\.insert\(|\bseen\w*\b|\bunique\w*\b|"
    r"uniqueKeysWithValues|Dictionary\(grouping:|\.removingDuplicates"
)


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def strip(src):
    src = re.sub(r'"""(?:.|\n)*?"""', '""', src)
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)
    src = re.sub(r"//[^\n]*", "", src)
    return re.sub(r"/\*(?:.|\n)*?\*/", "", src)


def match_brace(src, index):
    depth = 0
    for i in range(index, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def has_nested_for(body):
    for outer in FOR_RE.finditer(body):
        end = match_brace(body, outer.end() - 1)
        if end > 0 and FOR_RE.search(body, outer.end(), end):
            return True
    return False


def main():
    findings = []
    checked = 0
    for root in SCAN_ROOTS:
        for path in sorted(glob(os.path.join(REPO_ROOT, root, "**", "*.swift"), recursive=True)):
            src = strip(read(path))
            if not REPLACE_RE.search(src):
                continue
            rel = os.path.relpath(path, REPO_ROOT)
            for func in FUNC_RE.finditer(src):
                end = match_brace(src, func.end() - 1)
                if end < 0:
                    continue
                body = src[func.end():end]
                call = REPLACE_RE.search(body)
                if not call:
                    continue
                checked += 1
                if has_nested_for(body) and not DEDUPE_RE.search(body):
                    line = src.count("\n", 0, func.end() + call.start()) + 1
                    name = func.group(0).split("(")[0].replace("func", "").strip()
                    findings.append(
                        f"{rel}:{line}: {name} writes an ordered list built in "
                        f"nested loops without deduplicating its ids"
                    )
    if findings:
        print(f"{len(findings)} ordered list write(s) that can repeat an id:\n")
        for finding in findings:
            print(f"  {finding}")
        print("\nreplaceItems asserts unique ids: debug builds crash on a repeat.")
        return 1
    print(f"OK: no nested-loop ordered list write lacks a dedupe ({checked} writes checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
