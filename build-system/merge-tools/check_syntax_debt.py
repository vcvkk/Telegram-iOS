#!/usr/bin/env python3
"""Catch merge wreckage that only the Swift parser would otherwise find.

Two failure modes, both seen in this fork and both invisible until the module
they live in finally reaches the compiler — which, for anything under
`TelegramUI/Sources`, means after every other module in the graph is green:

1. **Leftover conflict markers.** A resolution that deletes `<<<<<<< ours` and
   the ours-side but forgets `=======` / `>>>>>>> theirs`. Eight such lines sat
   committed across five files in `TelegramUI/Sources`.

2. **Unbalanced delimiters.** `ChatControllerLoadDisplayNode.swift` carried a
   stray `)` where a `}` should have closed an `else` branch — one extra paren
   and one unclosed brace, which cancel out in any per-line review.

Counting delimiters on Swift needs a real left-to-right pass — stripping
comments and string literals with successive regex substitutions eats the tail
of every line holding a URL, because `//` inside `"https://t.me/…"` looks like a
line comment. That bug alone produced two false reports and, worse, masked the
two genuine ones above. With the single-pass stripper, only three files in the
tree come out unbalanced, all under a `#if`.

The count is still compared **against the same file upstream** wherever there is
a counterpart: both sides get the same residual parser noise and it cancels. A
fork-only file has nothing to compare against, so it gets the absolute rule
instead — a whole Swift file must close every brace it opens — and that half is
a gate, not advisory.

Usage:
    check_syntax_debt.py --upstream /tmp/upstream/release-<NEW> [--paths DIR ...]

Exits non-zero when anything is found.
"""

import argparse
import os
import re
import sys

DEFAULT_ROOTS = ["submodules", "exteraGram", "Telegram"]

MARKER = re.compile(r"^(?:<{7}|={7}$|>{7})")

def strip_noise(src):
    """Remove comments and string literals, in one left-to-right pass.

    Regex substitution in stages cannot do this: applying the line-comment
    pattern before the string pattern eats the tail of every line holding a URL
    ("https://t.me/\\(name)"), which silently deletes real delimiters. Two of
    the three files this checker flagged were that bug and not a merge defect.
    """
    out = []
    index = 0
    length = len(src)
    while index < length:
        char = src[index]
        if char == '"':
            if src.startswith('"""', index):
                end = src.find('"""', index + 3)
                index = length if end == -1 else end + 3
                continue
            index += 1
            while index < length:
                if src[index] == "\\":
                    # Skip an interpolation segment whole: it is balanced by
                    # construction, and its contents can hold nested quotes.
                    if index + 1 < length and src[index + 1] == "(":
                        depth = 0
                        index += 1
                        while index < length:
                            if src[index] == "(":
                                depth += 1
                            elif src[index] == ")":
                                depth -= 1
                                if depth == 0:
                                    index += 1
                                    break
                            index += 1
                        continue
                    index += 2
                    continue
                if src[index] == '"':
                    index += 1
                    break
                if src[index] == "\n":  # unterminated; do not run away
                    break
                index += 1
            continue
        if char == "/" and src.startswith("//", index):
            end = src.find("\n", index)
            index = length if end == -1 else end
            continue
        if char == "/" and src.startswith("/*", index):
            end = src.find("*/", index)
            index = length if end == -1 else end + 2
            continue
        out.append(char)
        index += 1
    return "".join(out)


def balances(src):
    code = strip_noise(src)
    return (
        code.count("{") - code.count("}"),
        code.count("(") - code.count(")"),
        code.count("[") - code.count("]"),
    )


def find_markers(src):
    return [
        (number, line.strip()[:40])
        for number, line in enumerate(src.split("\n"), 1)
        if MARKER.match(line)
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--upstream",
        help="upstream reference tree; without it only the marker check runs",
    )
    parser.add_argument("--paths", nargs="*", default=DEFAULT_ROOTS)
    args = parser.parse_args()

    problems = 0
    scanned = 0
    compared = 0
    drift = []
    fork_only = []

    for root in args.paths:
        for dirpath, _, filenames in os.walk(root):
            for name in filenames:
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                scanned += 1
                with open(path, encoding="utf-8", errors="replace") as handle:
                    ours = handle.read()

                markers = find_markers(ours)
                if markers:
                    for number, text in markers:
                        print(f"  {path}:{number}: conflict marker: {text}")
                        problems += 1
                    continue

                if not args.upstream:
                    continue
                reference = os.path.join(args.upstream, path)
                if not os.path.exists(reference):
                    # Fork-only: nothing to compare against, so use the absolute
                    # rule instead — a whole Swift file must close every brace
                    # it opens. Three files in the tree come out non-zero under
                    # a `#if`, and all three exist upstream, so this stays quiet
                    # here.
                    if balances(ours)[0] != 0:
                        fork_only.append(
                            f"  {path}: {{}} balance {balances(ours)[0]:+d} "
                            f"(fork-only file; a whole file must balance)"
                        )
                    continue
                with open(reference, encoding="utf-8", errors="replace") as handle:
                    theirs = handle.read()

                compared += 1
                for kind, mine, theirs_value in zip(
                    ("{}", "()", "[]"), balances(ours), balances(theirs)
                ):
                    if mine != theirs_value:
                        drift.append(
                            f"  {path}: {kind} balance {mine:+d} "
                            f"vs upstream {theirs_value:+d}"
                        )

    if drift:
        # Advisory only: a fork edit can legitimately shift these counts, and
        # the stripper does not understand every Swift literal form. Two real
        # merge breakages were found this way, so the list is worth reading —
        # but it is not a gate.
        print(f"\n{len(drift)} file(s) whose delimiter balance differs from upstream")
        print("(triage aid, not a failure — check any {} drift by hand):")
        for line in drift:
            print(line)

    if fork_only:
        print(f"\n{len(fork_only)} fork-only file(s) that do not close every brace:")
        for line in fork_only:
            print(line)

    if problems or fork_only:
        print(
            f"\nFAIL: {problems} conflict marker(s), "
            f"{len(fork_only)} unbalanced fork-only file(s) ({scanned} scanned)."
        )
        return 1

    print(f"\nOK: no conflict markers ({scanned} scanned, {compared} compared).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
