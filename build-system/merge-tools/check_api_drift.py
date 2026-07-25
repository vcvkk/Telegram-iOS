#!/usr/bin/env python3
"""Find fork API surfaces that fell behind upstream during a version bump.

The failure mode this catches: a cross-module bridge (a protocol requirement in
`AccountContext` and its implementation in `SharedAccountContext`) keeps its old
signature while every caller and the underlying factory move to the new one. The
compiler only reports it once the modules ahead of it in the build graph clear,
so it costs a full CI round each time. Three separate rounds of the 12.9.2 bump
were spent on exactly this (`makeTextProcessingScreen`, `makeAvatarMediaPicker\
Screen`, `makeLinkEditController`).

A plain textual diff against upstream is useless here: the fork deliberately
keeps `Peer`/`Message`/`PeerId` where upstream migrated to the Engine types, so
nearly every signature differs. This script normalises those known, intentional
substitutions away and reports only what is left — which is real drift.

Usage:
    check_api_drift.py --upstream /tmp/upstream/release-12.9.2 [--paths P ...]

Exits non-zero when drift is found.
"""

import argparse
import os
import re
import sys

# Files whose declarations are cross-module contracts: a mismatch here is not
# caught until late in the build, so they are worth checking eagerly.
DEFAULT_PATHS = [
    "submodules/AccountContext/Sources/AccountContext.swift",
    "submodules/TelegramUI/Sources/SharedAccountContext.swift",
]

# Deliberate fork divergence (see CLAUDE.md): the fork keeps the Postbox-level
# types where upstream moved to the Engine wrappers. Longest patterns first so
# that e.g. `EnginePeer.Id` is rewritten before `EnginePeer`.
FORK_SUBSTITUTIONS = [
    ("EngineHistoryViewInputTag", "HistoryViewInputTag"),
    ("EngineChatLocationInput", "ChatLocationInput"),
    ("EngineMessage.Index", "MessageIndex"),
    ("EngineMessage.Id", "MessageId"),
    ("EnginePeer.Id", "PeerId"),
    ("EngineRawMessage", "Message"),
    ("EngineRawPeer", "Peer"),
    ("EngineMessage", "Message"),
    ("EnginePeer", "Peer"),
]

# Module qualifiers are noise: `TelegramCore.EngineMessageHistoryThread.Info`
# and `EngineMessageHistoryThread.Info` are the same type.
MODULE_QUALIFIER = re.compile(
    r"\b(?:TelegramCore|Postbox|Display|TelegramUIPreferences|AccountContext)\."
)

FUNC_START = re.compile(r"\s*(?:public\s+|private\s+|internal\s+)?func\s+(\w+)\s*\(")


def collect_signatures(path):
    """Map function name -> list of one-line signatures declared in `path`."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().split("\n")

    signatures = {}
    index = 0
    while index < len(lines):
        match = FUNC_START.match(lines[index])
        if not match:
            index += 1
            continue

        # A signature may span many lines; consume until the parens balance.
        buffer = lines[index].strip()
        depth = buffer.count("(") - buffer.count(")")
        end = index
        while depth > 0 and end + 1 < len(lines):
            end += 1
            buffer += " " + lines[end].strip()
            depth += lines[end].count("(") - lines[end].count(")")

        # The return clause sometimes starts on the line after the closing paren.
        if "->" not in buffer and end + 1 < len(lines):
            following = lines[end + 1].strip()
            if following.startswith("->") or following.startswith("async"):
                end += 1
                buffer += " " + following

        buffer = re.sub(r"\s+", " ", buffer).rstrip(" {")
        signatures.setdefault(match.group(1), []).append(buffer)
        index = end + 1

    return signatures


def normalize(signature):
    """Erase the fork's intentional type divergence so only real drift remains."""
    result = MODULE_QUALIFIER.sub("", signature)
    for engine_type, fork_type in FORK_SUBSTITUTIONS:
        result = result.replace(engine_type, fork_type)
    # The fork keeps `postbox:` argument labels where upstream renamed them.
    result = result.replace("engine:", "postbox:")
    return result


def check(relative_path, upstream_root):
    upstream_path = os.path.join(upstream_root, relative_path)
    if not os.path.exists(relative_path) or not os.path.exists(upstream_path):
        print(f"skip {relative_path}: missing on one side")
        return []

    ours = collect_signatures(relative_path)
    theirs = collect_signatures(upstream_path)

    drift = []
    for name, our_signatures in ours.items():
        their_signatures = theirs.get(name)
        if not their_signatures:
            # Fork-only declaration, or one upstream removed — fork_inventory.py
            # owns that question.
            continue
        their_normalized = {normalize(s) for s in their_signatures}
        for signature in our_signatures:
            if normalize(signature) not in their_normalized:
                drift.append((name, signature, their_signatures[0]))
    return drift


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--upstream",
        required=True,
        help="root of the upstream reference tree (see fetch_upstream.sh)",
    )
    parser.add_argument(
        "--paths",
        nargs="*",
        default=DEFAULT_PATHS,
        help="repo-relative files to check",
    )
    args = parser.parse_args()

    total = 0
    for relative_path in args.paths:
        drift = check(relative_path, args.upstream)
        total += len(drift)
        if not drift:
            print(f"OK: {relative_path} — no API drift vs upstream")
            continue
        print(f"\n=== {relative_path}: {len(drift)} signature(s) drifted ===")
        for name, ours, theirs in drift:
            print(f"\n- {name}\n  OURS  : {ours}\n  THEIRS: {theirs}")

    if total:
        print(f"\nFAIL: {total} drifted signature(s).")
        print(
            "Each one is a cross-module bridge that will fail to compile only "
            "after the modules ahead of it build. Adopt the upstream signature "
            "unless the difference is deliberate fork divergence — in which "
            "case add the substitution to FORK_SUBSTITUTIONS."
        )
        return 1

    print("\nOK: no API drift.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
