#!/usr/bin/env python3
"""Condense a Bazel/Swift build log into a triage-sized error digest.

A failing full-app log is ~700 KB and repeats each diagnostic many times (once
per action attempt, plus notes and context lines). This extracts the unique
compiler diagnostics and the set of modules that failed to build.

Usage:
    parse_ci_errors.py build.log
    cat build.log | parse_ci_errors.py

Works both on a live CI log and on the JSON-escaped text returned by the GitHub
API (where newlines arrive as the two characters \\ and n).
"""

import re
import sys

# submodules/Foo/Sources/Bar.swift:12:34: error: message
DIAGNOSTIC_RE = re.compile(
    r"(?P<path>[\w./+-]+\.(?:swift|m|mm|h|c|cc|cpp)):"
    r"(?P<line>\d+):(?P<col>\d+): "
    r"(?P<kind>error|fatal error): "
    r"(?P<message>.*)"
)

# ERROR: /abs/path/submodules/Foo/BUILD:3:14: Compiling Swift module //submodules/Foo:Foo
FAILED_TARGET_RE = re.compile(
    r"ERROR: \S*?/((?:submodules|Telegram|exteraGram)/\S*?)/BUILD:\d+:\d+: "
    r"(?P<action>Compiling|Linking|Generating)"
)

# Bazel's own summary lines worth surfacing.
SUMMARY_RE = re.compile(r"(Elapsed time: [\d.]+s|processes: .*|\d+ disk cache hit)")


def normalize(raw: str) -> str:
    """Undo JSON escaping if the log came through the GitHub API."""
    if "\\n" in raw and raw.count("\n") < raw.count("\\n") / 4:
        raw = raw.replace("\\r\\n", "\n").replace("\\n", "\n").replace("\\t", "\t")
    return raw


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] != "-":
        with open(sys.argv[1], "r", errors="replace") as handle:
            text = normalize(handle.read())
    else:
        text = normalize(sys.stdin.read())

    diagnostics = {}  # dedupe key -> (path, line, col, message)
    failed_targets = []
    summary = []

    for raw_line in text.split("\n"):
        match = DIAGNOSTIC_RE.search(raw_line)
        if match:
            key = (match.group("path"), match.group("line"), match.group("col"),
                   match.group("message")[:160])
            diagnostics.setdefault(key, match.group("kind"))
            continue

        match = FAILED_TARGET_RE.search(raw_line)
        if match:
            module = match.group(1)
            if module not in failed_targets:
                failed_targets.append(module)
            continue

        match = SUMMARY_RE.search(raw_line)
        if match and match.group(1) not in summary:
            summary.append(match.group(1))

    if not diagnostics and not failed_targets:
        print("No compiler errors found in log.")
        # Still useful to see whether the cache worked.
        for item in summary:
            print(f"  {item}")
        return 0

    print(f"=== {len(diagnostics)} unique diagnostic(s) ===")
    # Group by file so related errors read together.
    by_file = {}
    for (path, line, col, message) in diagnostics:
        by_file.setdefault(path, []).append((int(line), int(col), message))
    for path in sorted(by_file):
        print(f"\n{path}")
        for line, col, message in sorted(by_file[path]):
            print(f"  :{line}:{col}: {message}")

    print(f"\n=== {len(failed_targets)} failed module(s) ===")
    for module in failed_targets:
        print(f"  {module}")

    if summary:
        print("\n=== build stats ===")
        for item in summary:
            print(f"  {item}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
