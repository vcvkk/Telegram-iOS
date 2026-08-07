#!/usr/bin/env python3
"""Compare each `combineLatest(...)` against the closure that consumes it.

This is the failure shape that costs the most CI rounds per line of damage in
this fork, and it has landed three times in the 12.9.2 bump alone:

    combineLatest(
        getFirstMessage(...),          <- fork signal, kept by the merge
        peerView,
        ...
    )
    |> mapToSignal { peerView, availablePanes, ... }   <- upstream header, took
                                                          the fork's binding out

Nothing is missing and nothing is extra. The merge took the *declaration* hunk
(the argument list, where the fork's line survives as an addition) from ours and
the *use* hunk (the closure header, one long line the fork also edited) from
theirs. Every binding then shifts by one, so the compiler reports a type error
several bindings downstream — "`availablePanes` is a `PeerView`" — and nothing
at all near the signal that actually moved.

SwiftSignalKit declares `combineLatest` as explicit overloads for 2...28
arguments plus an array form, so an off-by-one does not fail at the call: it
resolves to the neighbouring overload and fails inside the closure.

What is checked: for every `combineLatest(` whose result flows straight into
`|> map {` or `|> mapToSignal {`, the number of top-level arguments against the
number of closure parameters.

What is skipped, because the answer would be wrong rather than absent:
  - a closure with a single parameter. `combineLatest(a, b) |> map { values in
    values.0 }` and `|> mapToSignal { _ -> ... }` both bind the whole tuple to
    one name, which is legal at any arity; it is also indistinguishable from the
    array form (`combineLatest(queue:, xs.map { ... })`);
  - a `queue:` label, which is not a signal;
  - a closure whose parameter list is not a plain comma-separated name list
    (a destructured tuple, or `$0`).

Splitting the argument list has to survive `Signal<Void, NoError>`: that comma
is at paren depth zero and is not an argument separator. Angle brackets cannot
be tracked as delimiters (`|>`, `->` and comparisons all use them), so parts are
re-joined afterwards whenever one closes more generics than it opens.

A clean run is not proof — a closure that binds the right *number* of wrong
things still compiles here.

Usage:
    check_signal_arity.py [--paths DIR ...]

Exits non-zero when a mismatch is found.
"""

import argparse
import os
import re
import sys

DEFAULT_ROOTS = ["submodules", "exteraGram", "Telegram"]

CALL = re.compile(r"\bcombineLatest\s*\(")
# `|> map {` / `|> mapToSignal {`, allowing the pipe to sit on its own line.
CONSUMER = re.compile(r"\A\s*\|>\s*(map|mapToSignal)\s*\{")
PARAM_NAME = re.compile(r"\A[A-Za-z_][A-Za-z0-9_]*\Z")

OPENERS = {"(": ")", "[": "]", "{": "}"}
CLOSERS = {")", "]", "}"}


def match_paren(src, start):
    """Index just past the `)` closing the `(` at `start`, or None."""
    depth = 0
    index = start
    length = len(src)
    while index < length:
        char = src[index]
        if char == '"':
            index = skip_string(src, index)
            continue
        if char == "/" and index + 1 < length and src[index + 1] == "/":
            index = src.find("\n", index)
            if index == -1:
                return None
            continue
        if char == "/" and index + 1 < length and src[index + 1] == "*":
            index = src.find("*/", index)
            if index == -1:
                return None
            index += 2
            continue
        if char in OPENERS:
            depth += 1
        elif char in CLOSERS:
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return None


def skip_string(src, index):
    """Index just past the string literal starting at `index`."""
    if src.startswith('"""', index):
        end = src.find('"""', index + 3)
        return len(src) if end == -1 else end + 3
    index += 1
    while index < len(src):
        if src[index] == "\\":
            index += 2
            continue
        if src[index] == '"':
            return index + 1
        if src[index] == "\n":  # unterminated; do not run away
            return index
        index += 1
    return index


def split_arguments(body):
    """Top-level comma-separated arguments of a call body (parens excluded)."""
    parts = []
    depth = 0
    start = 0
    index = 0
    while index < len(body):
        char = body[index]
        if char == '"':
            index = skip_string(body, index)
            continue
        if char == "/" and body.startswith("//", index):
            index = body.find("\n", index)
            if index == -1:
                break
            continue
        if char in OPENERS:
            depth += 1
        elif char in CLOSERS:
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(body[start:index])
            start = index + 1
        index += 1
    parts.append(body[start:])
    return rejoin_generics([part for part in (p.strip() for p in parts) if part])


ARROWS = re.compile(r"\|>|->|>=|<=")


def rejoin_generics(parts):
    """Undo splits made on a comma inside `Signal<Void, NoError>`.

    A part that closes more angle brackets than it opens is the tail of a
    generic argument list, not an argument of its own. `|>`, `->`, `>=` and
    `<=` are removed first — they carry angle characters that mean nothing here.
    """
    joined = []
    for part in parts:
        stripped = ARROWS.sub("", part)
        if joined and stripped.count(">") > stripped.count("<"):
            joined[-1] = f"{joined[-1]}, {part}"
        else:
            joined.append(part)
    return joined


def closure_parameters(src, brace):
    """Parameter names of the closure whose `{` is at `brace`, or None."""
    header_end = len(src)
    for token in ("->", " in\n", " in ", "\n"):
        found = src.find(token, brace)
        if found != -1:
            header_end = min(header_end, found)
    header = src[brace + 1 : header_end].strip()
    if not header or "(" in header or "[" in header:
        return None
    names = [name.strip() for name in header.split(",")]
    if not all(PARAM_NAME.match(name) for name in names):
        return None
    return names


def check_file(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        src = handle.read()
    if "combineLatest" not in src:
        return []

    problems = []
    for match in CALL.finditer(src):
        open_paren = match.end() - 1
        close = match_paren(src, open_paren)
        if close is None:
            continue
        arguments = split_arguments(src[open_paren + 1 : close - 1])
        signals = [a for a in arguments if not a.startswith("queue:")]
        if len(signals) < 2:
            continue  # array form, or something the splitter did not understand

        tail = src[close:]
        consumer = CONSUMER.match(tail)
        if not consumer:
            continue
        parameters = closure_parameters(src, close + consumer.end() - 1)
        if parameters is None or len(parameters) == 1:
            continue
        if len(parameters) != len(signals):
            line = src.count("\n", 0, open_paren) + 1
            problems.append(
                f"  {path}:{line}: {len(signals)} signal(s) vs "
                f"{len(parameters)} closure parameter(s) "
                f"({consumer.group(1)})"
            )
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paths", nargs="*", default=DEFAULT_ROOTS)
    args = parser.parse_args()

    problems = []
    scanned = 0
    for root in args.paths:
        for dirpath, _, filenames in os.walk(root):
            for name in filenames:
                if not name.endswith(".swift"):
                    continue
                scanned += 1
                problems.extend(check_file(os.path.join(dirpath, name)))

    if problems:
        print(f"{len(problems)} arity mismatch(es) ({scanned} files scanned):\n")
        for line in problems:
            print(line)
        print(
            "\nCompare the argument list against the closure header against the "
            "pre-bump version of the file: the binding a merge drops is almost "
            "always a fork-added signal, and it is almost always the first one."
        )
        return 1

    print(f"OK: no combineLatest arity mismatches ({scanned} files scanned).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
