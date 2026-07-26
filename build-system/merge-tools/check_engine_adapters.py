#!/usr/bin/env python3
"""Find call sites that pass a Peer/Message across the fork's Engine boundary.

The fork deliberately keeps the Postbox-level `Peer` and `Message` where
upstream migrated to `EnginePeer` and `EngineMessage`. It did *not* do so
uniformly: some modules kept the old types, others arrived from upstream with
the new ones. Every call that crosses between them needs an adapter, and the
adapter is needed in **both** directions:

    Peer          -> EnginePeer      EnginePeer(x) / x.flatMap(EnginePeer.init)
    EnginePeer    -> Peer            x._asPeer()
    Message       -> EngineMessage   EngineMessage(x)
    EngineMessage -> Message         x._asMessage()

A missing adapter is a plain type error, but `--keep_going` only reports the
modules it can reach: the two failures of one 12.9.2 round hid 27 modules
behind them, so 16 more instances of an error it did report were invisible.
That is what this checks — the same class, everywhere at once, without waiting
for the module above to compile.

**This is not a type checker.** It reports a call site only when the declared
parameter type and the argument's type are *both* known with confidence, from
an explicit annotation rather than from inference. Anything it cannot resolve
it stays quiet about, so a clean run is not proof — it is the absence of the
cases that keep costing CI rounds. False positives are the expensive failure
here (a sweep that guesses produces dozens of wrong edits), so the resolver is
deliberately narrow.

Two traps encoded below, both of which produced wrong "findings" by hand:

  - `EnginePeer.Id` is a typealias for `PeerId`, and `EngineMessage.Id` for
    `MessageId`. Those parameters are identical on both sides and need no
    adapter; a sweep that ignores this reports hundreds of non-errors.
  - `EngineRawPeer` is a typealias for `Peer` and `EngineRawMessage` for
    `Message`, so a site that reads as Engine-shaped may already be correct.

Usage:
    check_engine_adapters.py                     # whole repo, exit 1 on findings
    check_engine_adapters.py submodules/TelegramUI
    check_engine_adapters.py --explain           # show why each type was resolved
"""

import os
import re
import sys
from collections import defaultdict
from glob import glob

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCAN_ROOTS = ["submodules", "exteraGram", "Telegram"]

# Canonical sides of the divergence. The Raw aliases resolve to the Postbox
# side because that is literally what they are.
POSTBOX_PEER, ENGINE_PEER = "Peer", "EnginePeer"
POSTBOX_MESSAGE, ENGINE_MESSAGE = "Message", "EngineMessage"

BASE_TYPES = {
    "Peer": POSTBOX_PEER,
    "EngineRawPeer": POSTBOX_PEER,
    "EnginePeer": ENGINE_PEER,
    "Message": POSTBOX_MESSAGE,
    "EngineRawMessage": POSTBOX_MESSAGE,
    "EngineMessage": ENGINE_MESSAGE,
}
COUNTERPART = {
    POSTBOX_PEER: ENGINE_PEER,
    ENGINE_PEER: POSTBOX_PEER,
    POSTBOX_MESSAGE: ENGINE_MESSAGE,
    ENGINE_MESSAGE: POSTBOX_MESSAGE,
}

# `EnginePeer.Id`, `EngineMessage.Index` and friends are typealiases for the
# Postbox types and are identical on both sides.
NESTED_RE = re.compile(r"\b(?:Engine)?(?:Raw)?(?:Peer|Message)\s*\.\s*\w+")

IDENTIFIER = r"[A-Za-z_]\w*"
# `let x: Peer?`, `var forwardSource: Peer?`, `public let message: Message`
ANNOTATED_RE = re.compile(
    rf"\b(?:public\s+|private\s+|fileprivate\s+|internal\s+|weak\s+|final\s+|"
    rf"static\s+|lazy\s+)*(?:let|var)\s+(?P<name>{IDENTIFIER})\s*:\s*(?P<type>[^=\n{{]+)"
)
TYPE_DECL_RE = re.compile(
    rf"^(?:public\s+|internal\s+|final\s+|open\s+)*"
    rf"(?:class|struct|enum|actor|protocol)\s+(?P<name>{IDENTIFIER})",
    re.M,
)
FUNC_RE = re.compile(
    rf"\b(?:public\s+|private\s+|internal\s+|open\s+|static\s+|class\s+|final\s+|"
    rf"override\s+)*func\s+(?P<name>{IDENTIFIER})\s*(?:<[^>]*>)?\s*\("
)
# `public let requestMessageUpdate: (EngineMessage.Id, Bool, ControlledTransition?) -> Void`
CLOSURE_PROP_RE = re.compile(
    rf"\b(?:public\s+|private\s+|internal\s+)*(?:let|var)\s+(?P<name>{IDENTIFIER})\s*:\s*\(\(?"
)


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def strip_comments(src):
    # Keep the line count identical: a block comment is replaced by its own
    # newlines, not deleted. Dropping them shifts every line number after the
    # comment, which reported a SharedAccountContext finding 262 lines early.
    src = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


# --------------------------------------------------------------------------
# type normalisation
# --------------------------------------------------------------------------

def classify(type_text):
    """Return (side, wrapper) or None if the type is outside the family.

    wrapper is "", "?" or "[]". A nested type such as `EnginePeer.Id` returns
    None: it is a typealias shared by both sides.
    """
    text = type_text.strip().rstrip(",")
    text = re.sub(r"\s*=\s*[^,]+$", "", text).strip()  # drop a default value
    if NESTED_RE.search(text):
        return None
    wrapper = ""
    array = re.fullmatch(r"\[\s*(.+?)\s*\]\??", text)
    if array:
        wrapper, text = "[]", array.group(1).strip()
    elif text.endswith("?"):
        wrapper, text = "?", text[:-1].strip()
    text = re.sub(r"^(?:any|some)\s+", "", text).strip()
    if not re.fullmatch(IDENTIFIER, text):
        return None
    side = BASE_TYPES.get(text)
    return (side, wrapper) if side else None


def adapter_for(from_side, to_side, wrapper, expr):
    """The edit that converts `expr` from one side to the other."""
    to_engine = to_side in (ENGINE_PEER, ENGINE_MESSAGE)
    engine_type = ENGINE_PEER if to_side == ENGINE_PEER or from_side == ENGINE_PEER else ENGINE_MESSAGE
    if to_engine:
        init = "EnginePeer" if engine_type == ENGINE_PEER else "EngineMessage"
        if wrapper == "?":
            return f"{expr}.flatMap({init}.init)"
        if wrapper == "[]":
            return f"{expr}.map({init}.init)"
        return f"{init}({expr})"
    method = "_asPeer" if engine_type == ENGINE_PEER else "_asMessage"
    if wrapper == "?":
        return f"{expr}?.{method}()"
    if wrapper == "[]":
        return f"{expr}.map {{ $0.{method}() }}"
    return f"{expr}.{method}()"


# --------------------------------------------------------------------------
# balanced-text helpers
# --------------------------------------------------------------------------

OPEN, CLOSE = "([{", ")]}"


def match_paren(src, index):
    """Index of the `)` matching the `(` at `index`, or -1."""
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
        elif ch in OPEN:
            depth += 1
        elif ch in CLOSE:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def split_args(text):
    """Top-level comma split, honouring nesting, strings and closures."""
    parts, depth, current, in_string = [], 0, [], False
    i = 0
    while i < len(text):
        ch = text[i]
        if in_string:
            current.append(ch)
            if ch == "\\" and i + 1 < len(text):
                current.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
            current.append(ch)
        elif ch in OPEN:
            depth += 1
            current.append(ch)
        elif ch in CLOSE:
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
        i += 1
    if "".join(current).strip():
        parts.append("".join(current))
    return [p.strip() for p in parts]


def parse_params(text):
    """[(label, name, type)] from a parameter list."""
    params = []
    for raw in split_args(text):
        if ":" not in raw:
            params.append((None, None, None))
            continue
        head, _, type_text = raw.partition(":")
        names = head.split()
        if len(names) >= 2:
            label, name = names[0], names[1]
        elif names:
            label = name = names[0]
        else:
            label = name = None
        params.append((None if label == "_" else label, name, type_text.strip()))
    return params


# --------------------------------------------------------------------------
# declaration index
# --------------------------------------------------------------------------

class Declarations:
    """Parameter lists by callee name, keeping only unambiguous entries.

    `direct` is what `foo(...)` calls; `returned` is the parameter list of the
    closure a function *returns*. They are kept apart because the chat
    rendering code never calls the latter by its own name:

        let forwardInfoLayout = ChatMessageForwardInfoNode.asyncLayout(node)
        ...
        forwardInfoLayout(context, presentationData, strings, type, peer, ...)

    There are 936 of those aliases in the tree, and four of the five
    diagnostics in one CI round were against exactly this shape, so resolving
    it is most of the tool's value.

    A name whose declarations disagree about a position is dropped rather than
    guessed at: two same-named functions in different modules is exactly the
    situation where a guess produces a wrong edit.
    """

    def __init__(self):
        self.direct = defaultdict(list)
        self.returned = defaultdict(list)

    def add(self, name, params, returns=False):
        # Deliberately unfiltered. An earlier version kept only lists with a
        # Peer/Message parameter, which silently dropped
        # `asyncLayout() -> (_ item: ChatMessageItem, ...)` — and `item` is not
        # itself in the family, it is the *receiver* of `item.message`. Two of
        # four known diagnostics were invisible because of that filter.
        # Filtering happens at use, where the parameter type is inspected.
        if params:
            (self.returned if returns else self.direct)[name].append(params)

    @staticmethod
    def _agree(entries):
        if not entries:
            return None
        first = entries[0]
        for other in entries[1:]:
            if len(other) != len(first):
                return None
            for a, b in zip(first, other):
                if (a[0], classify(a[2] or "")) != (b[0], classify(b[2] or "")):
                    return None
        return first

    def resolve(self, name):
        return self._agree(self.direct.get(name))

    def resolve_returned(self, name):
        return self._agree(self.returned.get(name))


def index_declarations(files):
    decls = Declarations()
    for path in files:
        src = strip_comments(read(path))
        spans = enclosing_types(src)

        for match in FUNC_RE.finditer(src):
            owner = enclosing_at(spans, match.start())
            open_paren = match.end() - 1
            close_paren = match_paren(src, open_paren)
            if close_paren < 0:
                continue
            decls.add(match.group("name"), parse_params(src[open_paren + 1:close_paren]))

            # `func asyncLayout(_ node: X?) -> (_ context: A, _ peer: EnginePeer?, ...) -> R`
            # The returned closure is what call sites actually invoke, and four
            # of five diagnostics in one round were against exactly this shape.
            tail = src[close_paren + 1: close_paren + 2000]
            arrow = re.match(r"\s*->\s*\(", tail)
            if arrow:
                inner_open = close_paren + 1 + arrow.end() - 1
                inner_close = match_paren(src, inner_open)
                if inner_close > 0:
                    # Keyed by owner: `asyncLayout` is declared on dozens of
                    # node types with different signatures, so the bare name is
                    # always ambiguous and would resolve to nothing.
                    params = parse_params(src[inner_open + 1:inner_close])
                    if owner:
                        decls.add(f"{owner}.{match.group('name')}", params,
                                  returns=True)

        for match in CLOSURE_PROP_RE.finditer(src):
            open_paren = src.rfind("(", match.start(), match.end())
            close_paren = match_paren(src, open_paren)
            if close_paren < 0:
                continue
            body = src[open_paren + 1:close_paren]
            if "->" in body:
                continue  # nested function type; not a plain parameter list
            decls.add(
                match.group("name"),
                [(None, None, t) for t in split_args(body)],
            )
    return decls


# --------------------------------------------------------------------------
# type facts
# --------------------------------------------------------------------------

def property_types(files):
    """type name -> {property: declared type}, for one-level `recv.prop`."""
    result = defaultdict(dict)
    for path in files:
        src = strip_comments(read(path))
        bounds = [(m.start(), m.group("name")) for m in TYPE_DECL_RE.finditer(src)]
        if not bounds:
            continue
        bounds.append((len(src), None))
        for (start, name), (end, _) in zip(bounds, bounds[1:]):
            for match in ANNOTATED_RE.finditer(src, start, end):
                if classify(match.group("type")):
                    result[name][match.group("name")] = match.group("type").strip()
    return result


# Every way a name gets bound. Only the annotated form carries a type; the
# others are recorded precisely so they can *shadow* an annotation that appears
# earlier in the file.
#
# Without this the checker is a false-positive machine. `peer` and `message`
# are re-bound dozens of times per file, so a file-wide identifier -> type map
# happily resolves `if case let .user(peer)` against an unrelated
# `let peer: EnginePeer?` two hundred lines away. That produced two wrong
# findings in ChatListItem and ChatTitleComponent on the first run.
BINDING_RES = [
    ("annotated", re.compile(
        rf"\b(?:public\s+|private\s+|fileprivate\s+|internal\s+|weak\s+|final\s+|"
        rf"static\s+|lazy\s+)*(?:let|var)\s+(?P<name>{IDENTIFIER})\s*:\s*(?P<type>[^=\n{{]+)")),
    ("assigned", re.compile(
        rf"\b(?:let|var)\s+(?P<name>{IDENTIFIER})\s*=\s*(?P<expr>[^\n]+)")),
    ("opaque", re.compile(
        rf"\bcase\s+let\s+\.{IDENTIFIER}\((?P<name>{IDENTIFIER})\)")),
    ("opaque", re.compile(
        rf"\b(?:if|guard|while)\s+(?:let\s+)?(?P<name>{IDENTIFIER})\s*[,{{]")),
    # closure parameter: `{ [weak self] peer in`, `{ peer, navigation in`
    ("opaque", re.compile(rf"\{{\s*(?:\[[^\]]*\]\s*)?(?P<name>{IDENTIFIER})\s+in\b")),
    ("opaque", re.compile(
        rf"\{{\s*(?:\[[^\]]*\]\s*)?(?P<name>{IDENTIFIER})\s*,[^\n]*?\s+in\b")),
]


def block_spans(src):
    """Every `{...}` span, innermost first, ignoring braces inside strings."""
    stack, spans = [], []
    in_string = False
    i = 0
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
            stack.append(i)
        elif ch == "}" and stack:
            spans.append((stack.pop(), i))
        i += 1
    spans.sort(key=lambda s: s[1] - s[0])
    return spans


def scope_end(spans, position, limit):
    """End of the innermost block containing `position`."""
    for start, end in spans:  # innermost first
        if start <= position < end:
            return end
    return limit


def closure_param_bindings(src, decls, spans):
    """Type the parameters of a returned layout closure.

        func asyncLayout() -> (_ item: ChatMessageItem, ...) -> X {
            return { item, params, ... in

    `item` is otherwise opaque, and `item.message` is one of the commonest
    ways the Message/EngineMessage divergence shows up in the chat nodes.
    """
    extra = []
    owners = enclosing_types(src)
    for match in FUNC_RE.finditer(src):
        owner = enclosing_at(owners, match.start())
        if not owner:
            continue
        params = decls.resolve_returned(f"{owner}.{match.group('name')}")
        if not params:
            continue
        body = src[match.end(): match.end() + 8000]
        ret = re.search(r"return\s*\{\s*(?:\[[^\]]*\]\s*)?([^}\n]*?)\s+in\b", body)
        if not ret:
            continue
        names = [n.strip() for n in ret.group(1).split(",")]
        if len(names) != len(params):
            continue
        position = match.end() + ret.start()
        end = scope_end(spans, position, len(src))
        for name, (_, _, declared) in zip(names, params):
            if re.fullmatch(IDENTIFIER, name) and declared:
                extra.append((name, position, "annotated", declared.strip(), end))
    return extra


def func_param_bindings(src, spans):
    """Function parameters, scoped to the function body.

    These giant node classes hand the real work to a static helper —
    `asyncLayout` returns a small closure that calls
    `beginLayout(selfReference, item, params, ...)` — so most of the code that
    touches `item` sees it as a *function parameter*, not as anything `let`
    ever bound. Leaving parameters out of the index made two known diagnostics
    unreachable.
    """
    out = []
    for match in FUNC_RE.finditer(src):
        open_paren = match.end() - 1
        close_paren = match_paren(src, open_paren)
        if close_paren < 0:
            continue
        brace = src.find("{", close_paren)
        if brace < 0:
            continue
        end = None
        for start, stop in spans:
            if start == brace:
                end = stop
                break
        if end is None:
            continue
        for _, name, declared in parse_params(src[open_paren + 1:close_paren]):
            if name and declared and re.fullmatch(IDENTIFIER, name):
                out.append((name, brace, "annotated", declared.strip(), end))
    return out


def bindings(src, decls=None):
    """name -> sorted [(position, kind, payload, scope_end)] for one file."""
    spans = block_spans(src)
    found = defaultdict(list)
    for name, position, kind, payload, end in func_param_bindings(src, spans):
        found[name].append((position, kind, payload, end))
    for kind, pattern in BINDING_RES:
        for match in pattern.finditer(src):
            groups = match.groupdict()
            payload = (groups.get("type") or groups.get("expr") or "").strip()
            found[groups["name"]].append((
                match.start(), kind, payload,
                scope_end(spans, match.start(), len(src)),
            ))
    if decls is not None:
        for name, position, kind, payload, end in closure_param_bindings(src, decls, spans):
            found[name].append((position, kind, payload, end))
    for name in found:
        found[name].sort()
    return found


def nearest_binding(binds, name, position):
    """The binding of `name` in effect at `position`, or None.

    Nearest-preceding *within a still-open block*. Plain nearest-preceding
    over-shadows: a `.map { item in ... }` four hundred lines earlier has long
    closed, but it would still hide the outer `item` and cost a real finding.
    Bindings whose block has already ended are skipped; a later binding that is
    still open shadows an earlier one, so an unresolvable form makes the
    checker stay quiet rather than guess.
    """
    best = None
    for start, kind, payload, end in binds.get(name, ()):
        if start >= position:
            break
        if position <= end:
            best = (kind, payload)
    return best


def receiver_type(name, position, binds, props, enclosing):
    """Declared type of `name` at `position`, following one `= self.prop` hop."""
    binding = nearest_binding(binds, name, position)
    if not binding:
        # A property of the type this code lives in, e.g. `self.item`.
        return props.get(enclosing, {}).get(name)
    kind, payload = binding
    if kind == "annotated":
        return payload
    if kind == "assigned":
        hop = re.fullmatch(rf"(?:self|strongSelf|{IDENTIFIER})\.({IDENTIFIER})",
                           payload.rstrip(" ,{"))
        if hop and enclosing:
            return props.get(enclosing, {}).get(hop.group(1))
    return None


def resolve_expression(expr, position, binds, props, enclosing):
    """(side, wrapper, why) for an argument expression, or None when unsure."""
    expr = expr.strip()

    if re.fullmatch(IDENTIFIER, expr):
        binding = nearest_binding(binds, expr, position)
        if binding and binding[0] == "annotated":
            found = classify(binding[1])
            if found:
                return found[0], found[1], f"nearest binding is `{expr}: {binding[1]}`"
        return None  # opaque or inferred: let the compiler decide

    member = re.fullmatch(rf"({IDENTIFIER})\.({IDENTIFIER})", expr)
    if member:
        receiver, prop = member.groups()
        base = receiver_type(receiver, position, binds, props, enclosing)
        if base:
            base = re.sub(r"[?\[\]]", "", base).strip()
            declared = props.get(base, {}).get(prop)
            if declared:
                found = classify(declared)
                if found:
                    return found[0], found[1], f"`{base}.{prop}: {declared}`"
    return None


def enclosing_types(src):
    """[(start, end, type name)] so a call site can name the type it sits in."""
    bounds = [(m.start(), m.group("name")) for m in TYPE_DECL_RE.finditer(src)]
    if not bounds:
        return []
    bounds.append((len(src), None))
    return [(a[0], b[0], a[1]) for a, b in zip(bounds, bounds[1:])]


def enclosing_at(spans, position):
    for start, end, name in spans:
        if start <= position < end:
            return name
    return None


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def swift_files(scope):
    files = []
    for root in scope:
        for path in glob(os.path.join(REPO_ROOT, root, "**", "*.swift"), recursive=True):
            rel = os.path.relpath(path, REPO_ROOT)
            if rel.startswith("bazel-") or "/bazel-" in rel:
                continue
            files.append(path)
    return sorted(files)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    explain = "--explain" in sys.argv
    scope = args or SCAN_ROOTS

    all_files = swift_files(SCAN_ROOTS)
    decls = index_declarations(all_files)
    props = property_types(all_files)

    target_files = swift_files(scope) if args else all_files

    findings = []
    calls_checked = 0

    for path in target_files:
        src = strip_comments(read(path))
        binds = bindings(src, decls)
        spans = enclosing_types(src)

        # `let forwardInfoLayout = ChatMessageForwardInfoNode.asyncLayout(node)`
        aliases = {}
        for alias in re.finditer(
            rf"\b(?:let|var)\s+({IDENTIFIER})\s*=\s*({IDENTIFIER})\s*\.\s*({IDENTIFIER})\s*\(",
            src,
        ):
            returned = decls.resolve_returned(f"{alias.group(2)}.{alias.group(3)}")
            if returned is not None:
                aliases[alias.group(1)] = returned

        for match in re.finditer(rf"\b({IDENTIFIER})\s*\(", src):
            name = match.group(1)
            params = aliases.get(name)
            if params is None:
                params = decls.resolve(name)
            if params is None:
                continue
            open_paren = match.end() - 1
            close_paren = match_paren(src, open_paren)
            if close_paren < 0:
                continue
            call_args = split_args(src[open_paren + 1:close_paren])
            if len(call_args) != len(params):
                continue  # overload or defaulted arguments: do not guess
            calls_checked += 1

            for (label, _, declared_type), argument in zip(params, call_args):
                expected = classify(declared_type or "")
                if not expected:
                    continue
                expr = argument
                if label and expr.startswith(label + ":"):
                    expr = expr[len(label) + 1:].strip()
                elif ":" in expr and re.match(rf"^{IDENTIFIER}\s*:", expr):
                    continue  # labelled differently: not this parameter
                actual = resolve_expression(
                    expr, match.start(), binds, props, enclosing_at(spans, match.start())
                )
                if not actual:
                    continue
                actual_side, actual_wrapper, why = actual
                if actual_side == expected[0]:
                    continue
                if COUNTERPART.get(actual_side) != expected[0]:
                    continue  # Peer vs Message: a different bug, not an adapter
                line = src[:match.start()].count("\n") + 1
                findings.append({
                    "file": os.path.relpath(path, REPO_ROOT),
                    "line": line,
                    "call": name,
                    "param": label or "(positional)",
                    "expected": declared_type.strip(),
                    "actual": why,
                    "fix": adapter_for(actual_side, expected[0], actual_wrapper, expr),
                    "expr": expr,
                })

    if not findings:
        print(f"OK: no missing Peer/Message adapter "
              f"({calls_checked} resolvable call(s) checked in "
              f"{len(target_files)} file(s)).")
        print("Note: this resolves types only from explicit annotations; "
              "a clean run is not a substitute for the compiler.")
        return 0

    print(f"FAIL: {len(findings)} call site(s) cross the Engine boundary "
          f"without an adapter:\n")
    by_file = defaultdict(list)
    for finding in findings:
        by_file[finding["file"]].append(finding)
    for file_name in sorted(by_file):
        print(file_name)
        for finding in sorted(by_file[file_name], key=lambda f: f["line"]):
            print(f"  :{finding['line']}: {finding['call']}("
                  f"{finding['param']}:) expects {finding['expected']}")
            print(f"      {finding['expr']}  ->  {finding['fix']}")
            if explain:
                print(f"      because {finding['actual']}")
        print()
    return 1


if __name__ == "__main__":
    sys.exit(main())
