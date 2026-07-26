#!/usr/bin/env python3
"""Cross-check Swift enum case declarations against the code that uses them.

A three-way merge splits an enum in half: the `case` list is one hunk, every
`switch self` arm is another, and the function that builds the values is a
third. Keeping our side of the case list while taking theirs for the arms
strands the enum, and the compiler only says so once every module below it has
already built. That is exactly what the 12.9.2 bump did to
`DebugSettingsUI.DebugControllerEntry`:

    :1342:19: type 'DebugControllerEntry' has no member 'debugRichText'
    :1634:25: type 'DebugControllerEntry' has no member 'debugRichText'

— upstream's `debugRichText` arm and its `entries.append(...)` came across, the
`case debugRichText(Bool)` declaration did not.

Three findings, all of them compile errors:

  undeclared    a `.name` in a `switch self` arm that the enum never declares;
  appended      `.name` appended to an array explicitly typed as the enum,
                where the enum never declares it;
  inexhaustive  a `switch self` with no `default:` that misses a declared case —
                the mirror-image failure, from taking the case list but not the
                arms.

Everything is resolved *lexically*: the enum a `switch self` belongs to is the
innermost type declaration around it, never a same-named type from another
module. `Content`, `Category`, `Message` and `ChannelParticipant` each name
several unrelated types in this tree, so name-keyed resolution reports nothing
but noise. Where the owner cannot be resolved that way the checker stays quiet,
so a clean run is not proof.

Usage:
    check_enum_cases.py                        # whole repo, exit 1 on findings
    check_enum_cases.py submodules/DebugSettingsUI
    check_enum_cases.py --all                  # include dirs bazel never builds
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from buildgraph import in_reachable, reachable_directories  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCAN_ROOTS = ["submodules", "exteraGram", "Telegram"]

DECL_RE = re.compile(
    r"\b(?P<kind>enum|struct|class|actor|protocol|extension)\s+"
    r"(?P<name>`?[A-Za-z_][\w.]*`?)"
)
# `class func` / `class var` are modifiers, not declarations.
NON_TYPE_NAMES = {"func", "var", "let", "init", "subscript", "deinit", "case"}

CASE_DECL_RE = re.compile(r"^[ \t]*(?:indirect\s+)?case\s+(?P<body>[^\n]*)$", re.M)
MEMBER_RE = re.compile(
    r"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|private\s+|fileprivate\s+|internal\s+|open\s+|final\s+|"
    r"static\s+|class\s+|lazy\s+|weak\s+|unowned\s+|override\s+|mutating\s+|"
    r"nonisolated\s+|dynamic\s+)*"
    r"(?:let|var|func|typealias|struct|class|enum|protocol|actor)\s+"
    r"(?P<name>`?[A-Za-z_]\w*`?)",
    re.M,
)
ARRAY_DECL_RE = re.compile(
    r"\b(?:let|var)\s+(?P<var>[A-Za-z_]\w*)\s*:\s*\[\s*(?P<type>[A-Za-z_]\w*)\s*\]"
)

# Members every enum answers to whatever it declares.
IMPLICIT_MEMBERS = {
    "self", "Type", "init", "allCases", "rawValue", "RawValue", "hashValue",
    "AllCases", "none", "some",
}


def unquote(name):
    return name.strip("`")


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def strip_noise(src):
    """Blank out comments and string literals, preserving offsets and lines."""
    out = list(src)
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif ch == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 1
            j = i + 2
            while j < n and depth:
                if src[j] == "/" and j + 1 < n and src[j + 1] == "*":
                    depth += 1
                    j += 2
                elif src[j] == "*" and j + 1 < n and src[j + 1] == "/":
                    depth -= 1
                    j += 2
                else:
                    j += 1
            for k in range(i, min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif ch == '"':
            if src.startswith('"""', i):
                j = src.find('"""', i + 3)
                j = n if j < 0 else j + 3
            else:
                j = i + 1
                while j < n and src[j] not in '"\n':
                    j += 2 if src[j] == "\\" else 1
                j = min(j + 1, n)
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def match_brace(src, open_index):
    """Index of the `}` closing the `{` at open_index, or len(src)."""
    depth = 0
    i = open_index
    n = len(src)
    while i < n:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def line_of(src, index):
    return src.count("\n", 0, index) + 1


def brace_pairs(src):
    """Every matched `{`…`}` in a file as (open index, close index)."""
    pairs = []
    stack = []
    for i, ch in enumerate(src):
        if ch == "{":
            stack.append(i)
        elif ch == "}" and stack:
            pairs.append((stack.pop(), i))
    return pairs


def innermost_pair_end(pairs, index, default):
    """End of the tightest brace block around index — a local variable's scope."""
    best = None
    for open_index, close_index in pairs:
        if open_index < index < close_index and (best is None or open_index > best[0]):
            best = (open_index, close_index)
    return best[1] if best else default


def split_top_level(text, separator=","):
    parts = []
    depth = 0
    current = []
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == separator and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
    parts.append("".join(current))
    return parts


def member_declarations(body):
    """Names declared directly in a type body (brace depth 0 of that body)."""
    names = set()
    depth = 0
    for line in body.split("\n"):
        if depth == 0:
            match = MEMBER_RE.match(line)
            if match:
                names.add(unquote(match.group("name")))
        depth = max(depth + line.count("{") - line.count("}"), 0)
    return names


def declared_cases(body, base_line):
    """[(case name, line)] declared directly in an enum body."""
    cases = []
    depth = 0
    offset = 0
    for line in body.split("\n"):
        if depth == 0:
            match = CASE_DECL_RE.match(line)
            if match:
                # `case a, b(Int), c = 3` — one declaration, several names.
                for chunk in split_top_level(match.group("body")):
                    name = re.match(r"\s*(`?[A-Za-z_]\w*`?)", chunk)
                    if name:
                        cases.append((unquote(name.group(1)), base_line + offset))
        depth = max(depth + line.count("{") - line.count("}"), 0)
        offset += 1
    return cases


class Decl:
    """One `enum` / `struct` / `class` / `extension` … body in one file."""

    def __init__(self, kind, name, path, start, end):
        self.kind = kind
        self.name = name
        self.path = path
        self.start = start          # first index inside the body
        self.end = end              # index of the closing brace
        self.cases = []
        self.members = set()

    @property
    def case_names(self):
        return {name for name, _ in self.cases}

    def contains(self, index):
        return self.start <= index < self.end


def parse_declarations(src, path):
    """Every type/extension body in a file, outermost first."""
    decls = []
    for match in DECL_RE.finditer(src):
        name = unquote(match.group("name"))
        if name in NON_TYPE_NAMES:
            continue
        before = src[:match.start()].rstrip()
        # `.enum` / `foo.class` are member accesses, not declarations.
        if before.endswith(".") or before.endswith("#"):
            continue
        brace = src.find("{", match.end())
        if brace < 0:
            continue
        # A `{` on the far side of a statement terminator is somebody else's.
        if ";" in src[match.end():brace]:
            continue
        end = match_brace(src, brace)
        decls.append(Decl(match.group("kind"), name, path, brace + 1, end))
    return decls


def innermost(decls, index):
    """Smallest declaration body containing index — the type `self` refers to."""
    best = None
    for decl in decls:
        if decl.contains(index) and (best is None or decl.start > best.start):
            best = decl
    return best


def switch_self_blocks(src, start, end):
    """(body_text, body_start) for every `switch self { … }` in a range."""
    for match in re.finditer(r"\bswitch\s+self\s*\{", src[start:end]):
        brace = start + match.end() - 1
        close = match_brace(src, brace)
        yield src[brace + 1:close], brace + 1


def starts_statement(block, index):
    """True when `case` at index opens a switch arm rather than a condition.

    Arm patterns start their own line in this codebase; `if case .x = y`,
    `else if case`, `guard case` and `for case` never do. Arm bodies are not
    braced, so those conditions sit at the same brace depth as the arms and are
    otherwise indistinguishable from them.
    """
    i = index - 1
    while i >= 0 and block[i] in " \t":
        i -= 1
    return i < 0 or block[i] in "\n{;"


def switch_arms(block):
    """(pattern, has_where, offset) for the arms of *this* switch only.

    A nested `switch state { case .succeed: … }` inside an arm's closure sits at
    brace depth > 0 and belongs to another type.
    """
    depth = 0
    i = 0
    n = len(block)
    while i < n:
        ch = block[i]
        if ch in "([{":
            depth += 1
            i += 1
            continue
        if ch in ")]}":
            depth -= 1
            i += 1
            continue
        if depth == 0 and block.startswith("case", i) \
                and (i == 0 or not (block[i - 1].isalnum() or block[i - 1] in "_.`")) \
                and i + 4 < n and not (block[i + 4].isalnum() or block[i + 4] in "_`") \
                and starts_statement(block, i):
            start = i + 4
            j = start
            pattern_depth = 0
            while j < n:
                c = block[j]
                if c in "([{":
                    pattern_depth += 1
                elif c in ")]}":
                    pattern_depth -= 1
                elif c == ":" and pattern_depth == 0:
                    break
                j += 1
            yield block[start:j], bool(re.search(r"\bwhere\b", block[start:j])), start
            i = j
            continue
        i += 1


def has_default_arm(block):
    depth = 0
    for i, ch in enumerate(block):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif depth == 0 and block.startswith("default", i) \
                and (i == 0 or not (block[i - 1].isalnum() or block[i - 1] in "_.")) \
                and re.match(r"default\s*:", block[i:]):
            return True
    return False


def top_level_dot_names(pattern):
    """`.name` references at paren depth 0 of a switch pattern."""
    names = []
    depth = 0
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "." and depth == 0:
            match = re.match(r"\.\s*(`?[A-Za-z_]\w*`?)", pattern[i:])
            if match and not (i and (pattern[i - 1].isalnum() or pattern[i - 1] in "_)`")):
                names.append(unquote(match.group(1)))
                i += match.end() - 1
        i += 1
    return names


def binds_whole_value(pattern):
    """`case let x:` / `case _:` — a catch-all that makes the switch exhaustive."""
    text = pattern.strip()
    if not text:
        return False
    return not top_level_dot_names(pattern)


def iter_swift_files(scope):
    for root in scope:
        base = os.path.join(REPO_ROOT, root)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if not d.startswith("bazel-")]
            for name in sorted(filenames):
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


def collect(scope):
    """Parse every file once: declarations per file, member names per type name."""
    files = {}
    members_by_name = {}
    enum_decls_by_name = {}
    for path in iter_swift_files(scope):
        src = strip_noise(read(path))
        decls = parse_declarations(src, path)
        for decl in decls:
            body = src[decl.start:decl.end]
            decl.members = member_declarations(body)
            if decl.kind == "enum":
                decl.cases = declared_cases(body, line_of(src, decl.start))
                enum_decls_by_name.setdefault(decl.name, []).append(decl)
            # Members are only ever used to *suppress* a finding, so pooling
            # them by name across modules is the safe direction to be wrong in.
            members_by_name.setdefault(decl.name, set()).update(decl.members)
            if decl.kind == "enum":
                members_by_name[decl.name].update(decl.case_names)
        files[path] = (src, decls)
    return files, members_by_name, enum_decls_by_name


def owning_enum(decls, index, enum_decls_by_name, path):
    """The enum `self` denotes at index, or None when it cannot be pinned down."""
    decl = innermost(decls, index)
    if decl is None:
        return None
    if decl.kind == "enum":
        return decl
    if decl.kind != "extension":
        return None  # a nested struct/class: `self` is not the enum
    candidates = [d for d in enum_decls_by_name.get(decl.name, []) if d.path == path]
    if len(candidates) == 1:
        return candidates[0]
    candidates = enum_decls_by_name.get(decl.name, [])
    return candidates[0] if len(candidates) == 1 else None


def check_file(path, src, decls, members_by_name, enum_decls_by_name, findings):
    rel = os.path.relpath(path, REPO_ROOT)

    for block, block_start in switch_self_blocks(src, 0, len(src)):
        enum_decl = owning_enum(decls, block_start, enum_decls_by_name, path)
        if enum_decl is None or not enum_decl.cases:
            continue
        declared = enum_decl.case_names
        allowed = declared | members_by_name.get(enum_decl.name, set()) | IMPLICIT_MEMBERS
        covered = set()
        exhaustive_candidate = not has_default_arm(block)
        for pattern, has_where, arm_offset in switch_arms(block):
            if has_where or binds_whole_value(pattern):
                exhaustive_candidate = False
            for name in top_level_dot_names(pattern):
                if name in declared:
                    covered.add(name)
                elif name not in allowed:
                    findings.append((
                        rel, line_of(src, block_start + arm_offset),
                        f"switch self arm uses .{name}, which "
                        f"{enum_decl.name} does not declare",
                    ))
        if exhaustive_candidate and covered and declared - covered:
            missing = ", ".join(sorted(declared - covered))
            findings.append((
                rel, line_of(src, block_start),
                f"switch self over {enum_decl.name} has no default and "
                f"never handles: {missing}",
            ))

    # `var entries: [SomeEntry] = []` … `entries.append(.name(…))`
    #
    # Scoped to the block the declaration lives in: one file routinely declares
    # `var entries: [A]` in one function and `var entries: [B]` in the next.
    pairs = brace_pairs(src)
    for match in ARRAY_DECL_RE.finditer(src):
        name = match.group("type")
        local = [d for d in enum_decls_by_name.get(name, []) if d.path == path]
        candidates = local if local else enum_decls_by_name.get(name, [])
        if len(candidates) != 1 or not candidates[0].cases:
            continue
        enum_decl = candidates[0]
        scope_end = innermost_pair_end(pairs, match.start(), len(src))
        allowed = (enum_decl.case_names | members_by_name.get(enum_decl.name, set())
                   | IMPLICIT_MEMBERS)
        pattern = re.compile(
            r"\b" + re.escape(match.group("var")) +
            r"\s*\.\s*(?:append|insert)\s*\(\s*\.\s*(`?[A-Za-z_]\w*`?)"
        )
        for use in pattern.finditer(src, match.end(), scope_end):
            case_name = unquote(use.group(1))
            if case_name not in allowed:
                findings.append((
                    rel, line_of(src, use.start()),
                    f"appends .{case_name} to [{enum_decl.name}], which "
                    f"{enum_decl.name} does not declare",
                ))


def main():
    scope = [a for a in sys.argv[1:] if not a.startswith("-")] or SCAN_ROOTS
    files, members_by_name, enum_decls_by_name = collect(scope)

    live = None if "--all" in sys.argv else reachable_directories(REPO_ROOT)

    findings = []
    enum_count = sum(len(v) for v in enum_decls_by_name.values())
    for path, (src, decls) in sorted(files.items()):
        # Directories outside the app's dependency graph never reach a compiler.
        if live is not None and not in_reachable(os.path.relpath(path, REPO_ROOT), live):
            continue
        check_file(path, src, decls, members_by_name, enum_decls_by_name, findings)

    if not findings:
        print(f"OK: enum cases and their uses agree ({enum_count} enums, "
              f"{len(files)} files checked).")
        return 0

    print(f"FAIL: {len(findings)} enum inconsistency(ies):\n")
    current = None
    for rel, line, message in sorted(findings):
        if rel != current:
            print(rel)
            current = rel
        print(f"  :{line}: {message}")
    print()
    return 1


if __name__ == "__main__":
    sys.exit(main())
