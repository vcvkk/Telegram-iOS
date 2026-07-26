#!/usr/bin/env python3
"""Check initializer call sites against the initializer they resolve to.

When upstream adds a parameter to a type in one module, every call site in every
other module has to grow an argument. A three-way merge takes the declaration
hunk and the call-site hunks independently, so it routinely takes one and not
the other — and Swift only reports it once everything below the caller's module
has already compiled. The 12.9.2 bump lost exactly one of these:

    submodules/WebUI/Sources/WebAppController.swift
      :3817:108: missing argument for parameter 'accentDisabledButtonColor' in call

`NavigationBarTheme` grew `accentDisabledButtonColor` upstream; eleven call
sites were updated and this one was not.

The checker resolves nothing it cannot see. It only considers a type when

  * the tree declares that name exactly once, as a struct/class/enum/actor;
  * at least one `init` is declared in the type's own body and none of them is
    an `override` (an init only in an extension leaves a struct's memberwise
    init alive, a lone `convenience init` means the class inherits designated
    ones, and an override means a superclass whose initializers are not here);
  * no initializer takes a variadic parameter.

and it only reports a call when every supplied label matches a parameter, in
order — so a call that actually resolves to an inherited or overloaded
initializer looks unfamiliar and is passed over rather than guessed at. A clean
run is therefore not proof.

Two findings:

  missing   a parameter with no default value that the call never supplies;
  unknown   a single argument label the initializer does not declare (an
            upstream rename that reached the declaration but not the caller).

Usage:
    check_init_args.py                     # whole repo, exit 1 on findings
    check_init_args.py submodules/WebUI
    check_init_args.py --all               # include directories bazel never builds
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from buildgraph import in_reachable, reachable_directories  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCAN_ROOTS = ["submodules", "exteraGram", "Telegram"]

TYPE_DECL_RE = re.compile(
    r"\b(?P<kind>struct|class|actor|enum|protocol|extension)\s+"
    r"(?P<name>[A-Za-z_][\w.]*)"
)
NON_TYPE_NAMES = {"func", "var", "let", "init", "subscript", "deinit", "case"}
INIT_RE = re.compile(r"(?<![\w.])init\s*[?!]?\s*(?P<generic><[^\n{(]*>)?\s*\(")
CALL_RE = re.compile(r"(?<![\w.$])(?P<name>[A-Z][A-Za-z0-9_]*)\s*\(")


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
    depth = 0
    i = open_index
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(src)


def match_paren(src, open_index):
    """Index of the `)` closing the `(` at open_index, or -1 if unbalanced."""
    depth = 0
    i = open_index
    while i < len(src):
        ch = src[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def line_of(src, index):
    return src.count("\n", 0, index) + 1


def split_arguments(text):
    """Split a parameter or argument list on its top-level commas.

    Blank chunks are kept: string literals are blanked out before parsing, so
    `ParseError(reader.getPos(), "…")` arrives here with an empty second
    argument that still occupies a parameter slot.
    """
    if not text.strip():
        return []
    parts = []
    depth = 0
    current = []
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
    parts.append("".join(current))
    return parts


def parse_parameters(text):
    """[(label or None, has default)] for a parameter list, or None if unparseable."""
    params = []
    for chunk in split_arguments(text):
        chunk = chunk.strip()
        if not chunk:
            continue
        if "..." in chunk:
            return None  # variadic: argument counting stops meaning anything
        head = chunk.split(":", 1)[0].strip()
        names = head.split()
        if not names or not re.fullmatch(r"[`\w]+", names[0]):
            return None
        label = names[0].strip("`")
        params.append((None if label == "_" else label, "=" in chunk))
    return params


def parse_call_labels(text):
    """[label or None] for an argument list, or None if it cannot be read."""
    if "#if" in text or "#endif" in text:
        return None  # conditional arguments: two different call shapes in one
    labels = []
    for chunk in split_arguments(text):
        match = re.match(r"\s*([A-Za-z_]\w*)\s*:(?!:)", chunk)
        labels.append(match.group(1) if match else None)
    return labels


def match_labels(params, supplied):
    """Walk supplied labels along the parameter list.

    Returns (missing, unknown) where `missing` lists parameters with no default
    that were never supplied, or None when the call does not line up with this
    initializer at all — an inherited or overloaded init we must not guess at.
    """
    missing = []
    unknown = []
    i = 0
    for label in supplied:
        start = i
        while i < len(params) and params[i][0] != label:
            i += 1
        if i == len(params):
            if label is None:
                # An unlabelled argument we cannot place: the call is not
                # shaped like this initializer, or our parse of it is wrong.
                return None
            i = start
            unknown.append(label)
            if len(unknown) > 1:
                return None
            continue
        for skipped_label, has_default in params[start:i]:
            if not has_default:
                missing.append(skipped_label or "_")
        i += 1
    for label, has_default in params[i:]:
        if not has_default:
            missing.append(label or "_")
    return missing, unknown


def iter_swift_files(scope):
    for root in scope:
        base = os.path.join(REPO_ROOT, root)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if not d.startswith("bazel-")]
            for name in sorted(filenames):
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


class TypeInfo:
    def __init__(self, name, kind, path):
        self.name = name
        self.kind = kind
        self.path = path
        self.declarations = 0       # how many *types* in the tree carry this name
        self.inits = []             # [(params, path, line, in_own_body)]
        self.unparseable_init = False
        self.inherits_initializers = False


def collect(scope):
    """Type declarations and their initializers, plus every file's source."""
    types = {}
    sources = {}
    for path in iter_swift_files(scope):
        src = strip_noise(read(path))
        sources[path] = src
        depths = brace_depths(src)
        for match in TYPE_DECL_RE.finditer(src):
            name = match.group("name").split(".")[0]
            kind = match.group("kind")
            if name in NON_TYPE_NAMES:
                continue
            before = src[:match.start()].rstrip()
            if before.endswith(".") or before.endswith("#"):
                continue
            brace = src.find("{", match.end())
            if brace < 0 or ";" in src[match.end():brace]:
                continue
            end = match_brace(src, brace)
            info = types.get(name)
            if info is None:
                info = types[name] = TypeInfo(name, kind, path)
            if kind != "extension":
                # An `extension Foo` seen before `class Foo` must not count as
                # a second declaration of Foo.
                info.declarations += 1
                info.kind = kind
                info.path = path
            record_inits(src, depths, brace + 1, end, info, path,
                         in_own_body=(kind != "extension"))
    return types, sources


def record_inits(src, depths, start, end, info, path, in_own_body):
    """Initializers declared directly in a type body (not in a nested type)."""
    base = depths[start - 1] if start else 0
    for match in INIT_RE.finditer(src, start, end):
        if depths[match.start()] != base:
            continue  # nested type, or a closure inside a member
        line_start = src.rfind("\n", 0, match.start()) + 1
        modifiers = src[line_start:match.start()]
        if "override" in modifiers:
            # An overridden initializer means a superclass, and the ones it
            # inherits are not in this tree — `MediaEditorPreviewView` overrides
            # MTKView's `init(frame:device:)` and callers use `init(frame:)`.
            info.inherits_initializers = True
        if match.group("generic"):
            info.unparseable_init = True
            continue
        open_paren = match.end() - 1
        close_paren = match_paren(src, open_paren)
        if close_paren < 0:
            info.unparseable_init = True
            continue
        params = parse_parameters(src[open_paren + 1:close_paren])
        if params is None:
            info.unparseable_init = True
            continue
        info.inits.append((
            params, path, line_of(src, match.start()),
            in_own_body and "convenience" not in modifiers,
        ))


def brace_depths(src):
    """Brace depth at every index, so a member's nesting is a subtraction."""
    depths = [0] * len(src)
    depth = 0
    for i, ch in enumerate(src):
        if ch == "{":
            depth += 1
        depths[i] = depth
        if ch == "}":
            depth -= 1
    return depths


def candidates(types):
    """Types whose initializers are all visible, keyed by name.

    Overloads are kept: `NavigationBarTheme` declares the full initializer in
    its own body and a `convenience init(rootControllerTheme:)` in an extension
    in another module, and a call site may mean either.
    """
    result = {}
    for name, info in types.items():
        if info.kind not in ("struct", "class", "actor", "enum"):
            continue
        if info.declarations != 1 or info.unparseable_init or not info.inits:
            continue
        if info.inherits_initializers:
            continue
        # No initializer in the type's own body means the ones that matter are
        # invisible from here: a struct's memberwise init, or a class's
        # inherited designated initializers.
        if not any(own for _, _, _, own in info.inits):
            continue
        overloads = [
            (params, os.path.relpath(path, REPO_ROOT), line)
            for params, path, line, _ in info.inits if params
        ]
        if overloads:
            result[name] = overloads
    return result


def check_file(path, src, checkable, findings):
    rel = os.path.relpath(path, REPO_ROOT)
    for match in CALL_RE.finditer(src):
        overloads = checkable.get(match.group("name"))
        if overloads is None:
            continue
        before = src[:match.start()].rstrip()
        if re.search(r"\b(?:case|func|class|struct|enum|actor|protocol|extension)$", before):
            continue
        open_paren = match.end() - 1
        close_paren = match_paren(src, open_paren)
        if close_paren < 0:
            continue
        # A trailing closure supplies the last parameter without a label.
        if src[close_paren + 1:close_paren + 3].lstrip().startswith("{"):
            continue
        supplied = parse_call_labels(src[open_paren + 1:close_paren])
        if supplied is None or not supplied:
            continue

        outcomes = []
        for params, decl_rel, decl_line in overloads:
            outcome = match_labels(params, supplied)
            if outcome is None:
                continue
            missing, unknown = outcome
            if not missing and not unknown:
                outcomes = None  # one overload takes this call as written
                break
            outcomes.append((missing, unknown, decl_rel, decl_line))
        if outcomes is None:
            continue

        # Report only when a single initializer is a near miss. Two candidates
        # mean overload resolution, which this checker does not attempt.
        near = [o for o in outcomes if o[0] and not o[1]]
        renamed = [o for o in outcomes if not o[0] and len(o[1]) == 1]
        line = line_of(src, match.start())
        name = match.group("name")
        if len(near) == 1 and not renamed:
            missing, _, decl_rel, decl_line = near[0]
            findings.append((
                rel, line,
                f"{name}(…) is missing required argument(s) "
                f"{', '.join(repr(m) for m in missing)} ({decl_rel}:{decl_line})",
            ))
        elif len(renamed) == 1 and not near:
            _, unknown, decl_rel, decl_line = renamed[0]
            findings.append((
                rel, line,
                f"{name}(…) passes '{unknown[0]}:', which its initializer does "
                f"not declare ({decl_rel}:{decl_line})",
            ))


def main():
    scope = [a for a in sys.argv[1:] if not a.startswith("-")] or SCAN_ROOTS
    include_unbuilt = "--all" in sys.argv
    # Declarations always come from the whole tree: a call site in one module is
    # checked against a type declared in another.
    types, sources = collect(SCAN_ROOTS)
    checkable = candidates(types)

    selected = [
        path for path in sources
        if any(os.path.relpath(path, REPO_ROOT).startswith(s.rstrip("/") + os.sep)
               or os.path.relpath(path, REPO_ROOT) == s
               for s in scope)
    ] if scope != SCAN_ROOTS else list(sources)

    if not include_unbuilt:
        # `submodules/LegacyDataImport` and `exteraGram/Playground` are not in
        # the app's dependency graph, so their drift can never fail CI.
        live = reachable_directories(REPO_ROOT)
        selected = [p for p in selected
                    if in_reachable(os.path.relpath(p, REPO_ROOT), live)]

    findings = []
    for path in sorted(selected):
        check_file(path, sources[path], checkable, findings)

    if not findings:
        print(f"OK: initializer call sites agree with their declarations "
              f"({len(checkable)} types, {len(selected)} files checked).")
        return 0

    print(f"FAIL: {len(findings)} initializer call site(s):\n")
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
