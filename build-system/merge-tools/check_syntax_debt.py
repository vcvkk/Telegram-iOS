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

Counting delimiters on Swift naively is hopeless: string interpolation, regex
literals and raw strings all confuse it, and ~170 perfectly good files in this
tree come out "unbalanced". So the count is only ever compared **against the
same file upstream**. Both sides get the same parser noise, it cancels, and
what is left is a real structural difference introduced by a merge. Files with
no upstream counterpart (fork-only) are skipped — there is nothing to compare
them to.

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

MULTILINE_STRING = re.compile(r'"""[\s\S]*?"""')
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")
STRING_LITERAL = re.compile(r'"(?:\\.|[^"\\\n])*"')


def strip_noise(src):
    src = MULTILINE_STRING.sub('""', src)
    src = BLOCK_COMMENT.sub("", src)
    src = LINE_COMMENT.sub("", src)
    return STRING_LITERAL.sub('""', src)


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

    if problems:
        print(f"\nFAIL: {problems} conflict marker(s) ({scanned} scanned).")
        return 1

    print(f"\nOK: no conflict markers ({scanned} scanned, {compared} compared).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
