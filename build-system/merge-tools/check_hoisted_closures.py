#!/usr/bin/env python3
"""A hoisted closure must hand its parameters to a callee that still wants them.

Commit fbcf2554 moved the fork's divergent arguments out of the two enormous
`ChatControllerInteraction` initializers into named closures:

    let openMessageContextMenuImpl: (Message, Bool, ASDisplayNode, CGRect,
                                     UIGestureRecognizer?, CGPoint?) -> Void = {
        [weak self] message, selectAll, node, frame, anyRecognizer, location in
        self.openMessageContextMenu(message: message, selectAll: selectAll, ...)
    }

That stops the fork's edits colliding with upstream on every bump, but it also
splits one expression into two declarations that a merge can move
independently: the annotation keeps the fork's `Message` while the method it
forwards to follows upstream to `EngineMessage`, and nothing connects them
until the compiler gets there — behind a ten-minute TelegramUI build, at the
very top of the dependency graph. The 12.9.2 bump had four of these.

`check_engine_adapters.py` cannot see them. It reads expressions, and the
expression here is a bare `message`, whose only type is the annotation on a
`let` several lines up; worse, the callee's name is ambiguous on purpose --
`openMessageContextMenu` is declared four times in this tree, once as the
`ChatControllerInteraction` property that takes the fork's `Message` and once
as the method that takes upstream's `EngineMessage`, so resolving by name
alone is exactly the wrong answer.

This checker compares two *declarations* instead, which is why it can afford
to be strict: the closure's own annotation against the callee's parameter
list, and only when the call's argument labels pick out exactly one
declaration in the tree. It reports only pairs that differ by the Engine
wrapper, since that is the divergence the fork maintains deliberately -- an
unrelated type mismatch is the compiler's business, not a merge hazard.

    python3 build-system/merge-tools/check_hoisted_closures.py
    python3 build-system/merge-tools/check_hoisted_closures.py --explain

Exit status is 1 when anything is reported. What it cannot see: an argument
that is not simply one of the closure's parameters (`if let x = actions.author`
needs real inference), and a callee whose labels match several declarations.
A clean run is not proof.
"""

import os
import re
import sys
from collections import defaultdict
from glob import glob

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from check_engine_adapters import (  # noqa: E402
    IDENTIFIER,
    match_paren,
    parse_params,
    split_args,
    strip_comments,
)

SCAN_ROOTS = ["submodules", "exteraGram", "Telegram"]

# The pairs the fork keeps apart on purpose. Everything else is left alone.
#
# Deliberately *not* here: `MessageId`/`EngineMessage.Id` and
# `PeerId`/`EnginePeer.Id`. Those spellings name the same type --
# `EnginePeer.Id` is `public typealias Id = PeerId` -- so a closure and its
# callee disagreeing on which one to write is a style difference, not a bug.
# Including them produced eleven false findings in SettingsUI and
# OpenResolvedUrl on the first run, against code that compiles.
ADAPTED = {
    "Message": "EngineMessage",
    "Peer": "EnginePeer",
}

DECL_RE = re.compile(
    rf"\b(?:public\s+|private\s+|fileprivate\s+|internal\s+|open\s+|final\s+|"
    rf"static\s+|class\s+|override\s+|convenience\s+|required\s+)*"
    rf"(?:func\s+(?P<name>{IDENTIFIER})|(?P<init>init)\??)\s*(?:<[^>(]*>)?\s*\("
)
TYPE_DECL_RE = re.compile(
    rf"\b(?:final\s+|public\s+|private\s+|internal\s+|open\s+)*"
    rf"(?:class|struct|enum|extension)\s+(?P<name>{IDENTIFIER})"
)
HOISTED_RE = re.compile(rf"\b(?:let|var)\s+(?P<name>{IDENTIFIER})\s*:\s*\(")
CALL_RE = re.compile(
    rf"(?:\b(?:self|strongSelf)\s*\.\s*)?\b(?P<name>{IDENTIFIER})\s*\("
)


def match_brace(src, index):
    """Index of the `}` closing the `{` at `index`, or -1. Strings are skipped."""
    depth = 0
    in_string = False
    i = index
    while i < len(src):
        ch = src[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def swift_files():
    files = []
    for root in SCAN_ROOTS:
        for path in glob(os.path.join(REPO_ROOT, root, "**", "*.swift"), recursive=True):
            rel = os.path.relpath(path, REPO_ROOT)
            if rel.startswith("bazel-") or "/bazel-" in rel:
                continue
            files.append(path)
    return sorted(files)


def normalise(text):
    """A type as it is written, with the noise a comparison should ignore."""
    return re.sub(r"\s+", "", text).lstrip("@escaping").strip()


def adapted_pair(closure_type, callee_type):
    """(from, to) when these two differ only by the Engine wrapper."""
    a, b = normalise(closure_type), normalise(callee_type)
    if a == b:
        return None
    for plain, engine in ADAPTED.items():
        # `Message` vs `EngineMessage`, `[Peer]` vs `[EnginePeer]`,
        # `Peer?` vs `EnginePeer?`, and the reverse of each.
        if a.replace(plain, engine, 1) == b or b.replace(plain, engine, 1) == a:
            return (a, b)
    return None


def index_by_labels(files):
    """(name, label tuple) -> [(path, parameter list)] across the whole tree."""
    index = defaultdict(list)
    for path in files:
        src = strip_comments(read(path))
        type_bounds = [(m.start(), m.group("name")) for m in TYPE_DECL_RE.finditer(src)]
        for match in DECL_RE.finditer(src):
            open_paren = match.end() - 1
            close_paren = match_paren(src, open_paren)
            if close_paren < 0:
                continue
            params = parse_params(src[open_paren + 1:close_paren])
            if not params:
                continue
            name = match.group("name")
            if match.group("init"):
                # An initializer is called by its type's name.
                owner = None
                for start, owner_name in type_bounds:
                    if start < match.start():
                        owner = owner_name
                    else:
                        break
                if not owner:
                    continue
                name = owner
            labels = tuple((label or "_") for label, _, _ in params)
            index[(name, labels)].append((os.path.relpath(path, REPO_ROOT), params))
    return index


def hoisted_closures(src):
    """[(name, {param name: declared type}, body start, body end)]."""
    out = []
    for match in HOISTED_RE.finditer(src):
        open_paren = match.end() - 1
        close_paren = match_paren(src, open_paren)
        if close_paren < 0:
            continue
        head = re.match(
            r"\s*->\s*[^={\n]*=\s*\{\s*(?:\[[^\]]*\]\s*)?(?P<names>[^}\n]*?)\s+in\b",
            src[close_paren + 1:],
        )
        if not head:
            continue
        names = [n.strip() for n in head.group("names").split(",")]
        types = [t.split(":")[-1].strip() for t in split_args(src[open_paren + 1:close_paren])]
        if len(names) != len(types) or not types:
            continue
        brace = close_paren + 1 + src[close_paren + 1:].index("{", head.start())
        end = match_brace(src, brace)
        if end < 0:
            continue
        typed = {
            name: declared
            for name, declared in zip(names, types)
            if re.fullmatch(IDENTIFIER, name) and declared
        }
        if typed:
            out.append((match.group("name"), typed, brace, end))
    return out


def inner_rebindings(src, body_start, body_end):
    """[(start, end, names)] for every scope inside a hoisted body that rebinds
    a name.

    `openMessageImpl` declares `message: Message`, but eight hundred lines down
    `navigateToMessageContext: { [weak self] message in` introduces a different
    `message` whose type comes from that argument's own signature. Treating the
    outer annotation as authoritative there reported
    `openMediaMessageContext(message:)` against code that compiles. Nested
    closure parameters and `let`/`guard let`/`if let` bindings both count; a
    `let` shadows until the end of the block it sits in.
    """
    out = []
    closure_re = re.compile(
        rf"\{{\s*(?:\[[^\]]*\]\s*)?(?P<names>(?:{IDENTIFIER}|_)(?:\s*,\s*(?:{IDENTIFIER}|_))*)\s+in\b"
    )
    for match in closure_re.finditer(src, body_start + 1, body_end):
        end = match_brace(src, match.start())
        if end < 0:
            continue
        names = {n.strip() for n in match.group("names").split(",")}
        out.append((match.start(), end, names))
    let_re = re.compile(rf"\b(?:let|var)\s+({IDENTIFIER})\b")
    for match in let_re.finditer(src, body_start + 1, body_end):
        # the innermost block containing the binding bounds its scope
        depth, i = 0, match.start()
        while i > body_start:
            ch = src[i]
            if ch == "}":
                depth += 1
            elif ch == "{":
                if depth == 0:
                    break
                depth -= 1
            i -= 1
        end = match_brace(src, i)
        if end > 0:
            out.append((match.start(), end, {match.group(1)}))
    return out


def check_file(path, index, findings, explain):
    src = strip_comments(read(path))
    rel = os.path.relpath(path, REPO_ROOT)
    for closure_name, typed, body_start, body_end in hoisted_closures(src):
        shadows = inner_rebindings(src, body_start, body_end)
        for call in CALL_RE.finditer(src, body_start, body_end):
            open_paren = call.end() - 1
            close_paren = match_paren(src, open_paren)
            if close_paren < 0 or close_paren > body_end:
                continue
            args = split_args(src[open_paren + 1:close_paren])
            if not args:
                continue
            labels, values = [], []
            for arg in args:
                head, sep, tail = arg.partition(":")
                if sep and re.fullmatch(IDENTIFIER, head.strip()):
                    labels.append(head.strip())
                    values.append(tail.strip())
                else:
                    labels.append("_")
                    values.append(arg.strip())
            matches = index.get((call.group("name"), tuple(labels)), [])
            if len(matches) != 1:
                continue  # ambiguous, or not a declaration this tree owns
            decl_path, params = matches[0]
            for value, (_, _, declared) in zip(values, params):
                if value not in typed or not declared:
                    continue
                if any(start < call.start() < end and value in names
                       for start, end, names in shadows):
                    continue  # a nested closure or `let` rebinds the name
                pair = adapted_pair(typed[value], declared)
                if not pair:
                    continue
                line = src.count("\n", 0, call.start()) + 1
                detail = f" (declared in {decl_path})" if explain else ""
                findings.append(
                    f"{rel}:{line}: `{closure_name}` declares "
                    f"`{value}: {pair[0]}` but {call.group('name')}(...) takes "
                    f"`{pair[1]}`{detail}"
                )


def main():
    explain = "--explain" in sys.argv
    files = swift_files()
    index = index_by_labels(files)
    findings = []
    for path in files:
        check_file(path, index, findings, explain)

    if findings:
        print(f"{len(findings)} hoisted closure(s) out of step with their callee:\n")
        for finding in sorted(set(findings)):
            print(f"  {finding}")
        print(
            "\nEither adapt the argument (`EngineMessage(x)`, `x._asPeer()`) or "
            "move the closure's annotation — whichever keeps the fork's behaviour."
        )
        return 1

    print(f"OK: hoisted closures agree with their callees ({len(files)} files checked).")
    print("Note: only arguments that are plain closure parameters are resolvable; "
          "a clean run is not a substitute for the compiler.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
