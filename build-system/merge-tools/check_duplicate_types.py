#!/usr/bin/env python3
"""Find duplicate top-level type declarations inside a single Swift module.

Two files in one module declaring the same type produce "invalid redeclaration"
plus a cascade of "is ambiguous for type lookup" errors across the module. In
the 12.8 bump this happened twice, and both times cost a full CI round:

  - BotPaymentsUI: BotCheckoutPaymentMethodSheet.swift (a stale file upstream had
    deleted) redeclared BotCheckoutPaymentMethod / BotCheckoutPaymentWebToken,
    already defined in BotCheckoutPaymentMethodScreen.swift.
  - TelegramUIPreferences: a stray Swiftgram SGUISettings.swift landed next to
    the fork's renamed ExteraGram/EGUISettings.swift.

Only same-module collisions are reported: the same type name in two different
modules is legal in Swift.

Usage:
    check_duplicate_types.py                 # whole repo, exit 1 on findings
    check_duplicate_types.py submodules/BotPaymentsUI
"""

import os
import re
import sys
from glob import glob

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCAN_ROOTS = ["submodules", "exteraGram", "Telegram"]

NAME_RE = re.compile(r'\bname\s*=\s*"([^"]+)"')
MODULE_NAME_RE = re.compile(r'\bmodule_name\s*=\s*"([^"]+)"')

# Top-level (column 0) declarations only — nested types are namespaced by their
# parent and cannot collide with each other.
#
# `private`/`fileprivate` top-level types are file-scoped, so the same name in
# two files of one module is legal and common in this codebase (SettingsUI alone
# has ~10 such pairs). Capture the modifiers so those can be filtered out.
DECL_RE = re.compile(
    r"^(?P<modifiers>(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|"
    r"final\s+|@\w+\s+|@\w+\([^)]*\)\s+)*)"
    r"(?P<kind>class|struct|enum|protocol|actor)\s+"
    r"(?P<name>[A-Za-z_]\w*)",
    re.M,
)
FILE_SCOPED_RE = re.compile(r"\b(?:private|fileprivate)\b")
# `extension Foo` is not a declaration of Foo.
EXTENSION_RE = re.compile(r"^extension\s", re.M)


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def strip_noise(src):
    """Remove comments, string literals and non-iOS conditional blocks."""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    src = re.sub(r'"""(?:.|\n)*?"""', '""', src)
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)
    return strip_non_ios_blocks(src)


def strip_non_ios_blocks(src):
    """Drop `#if os(macOS)` / `#if !os(iOS)` bodies — not compiled for iOS.

    lottie-ios ships macOS and iOS variants of the same class in one module and
    relies on this; without the filter every such pair looks like a duplicate.
    """
    lines = src.split("\n")
    out = []
    # Stack of booleans: True while inside a branch excluded from iOS builds.
    excluded_depth = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#if "):
            condition = stripped[4:]
            excluded_depth.append(_is_non_ios(condition))
            out.append("")
            continue
        if stripped.startswith("#elseif "):
            if excluded_depth:
                excluded_depth[-1] = _is_non_ios(stripped[8:])
            out.append("")
            continue
        if stripped == "#else":
            if excluded_depth:
                excluded_depth[-1] = not excluded_depth[-1]
            out.append("")
            continue
        if stripped == "#endif":
            if excluded_depth:
                excluded_depth.pop()
            out.append("")
            continue
        out.append("" if any(excluded_depth) else line)
    return "\n".join(out)


def _is_non_ios(condition):
    condition = condition.strip()
    if re.search(r"!\s*os\(\s*iOS\s*\)", condition):
        return True
    # `os(macOS)` / `os(watchOS)` etc. with no os(iOS) alternative in the same test
    if re.search(r"\bos\(\s*(?:macOS|OSX|watchOS|tvOS|visionOS|Linux|Windows)\s*\)",
                 condition) and not re.search(r"\bos\(\s*iOS\s*\)", condition):
        return True
    return False


def iter_modules(scope):
    """Yield (module_name, [source files]) for every swift_library in scope."""
    for root in scope:
        pattern = os.path.join(REPO_ROOT, root, "**", "BUILD")
        for build_path in glob(pattern, recursive=True):
            build_dir = os.path.dirname(build_path)
            rel_dir = os.path.relpath(build_dir, REPO_ROOT)
            if rel_dir.startswith("bazel-") or "/bazel-" in rel_dir:
                continue
            src = read(build_path)
            for match in re.finditer(r"swift_library\(\s*(.*?)\n\)", src, re.S):
                body = match.group(1)
                name_match = NAME_RE.search(body)
                if not name_match:
                    continue
                module = (MODULE_NAME_RE.search(body) or name_match).group(1)

                files = []
                srcs_match = re.search(
                    r"\bsrcs\s*=\s*(.*?)(?:\n\s{4}\w+\s*=|\n\s*\)\s*,?\s*$|\Z)",
                    body, re.S | re.M,
                )
                if srcs_match:
                    srcs_text = srcs_match.group(1)
                    # glob(include, exclude = [...]) — honour the exclude list,
                    # e.g. TelegramVoip excludes Sources/macOS/**/*.
                    exclude_match = re.search(
                        r"exclude\s*=\s*\[(.*?)\]", srcs_text, re.S
                    )
                    exclude_patterns = (
                        re.findall(r'"([^"]+)"', exclude_match.group(1))
                        if exclude_match else []
                    )
                    include_text = (
                        srcs_text[: exclude_match.start()] if exclude_match else srcs_text
                    )
                    excluded = set()
                    for pattern_str in exclude_patterns:
                        excluded.update(
                            glob(os.path.join(build_dir, pattern_str), recursive=True)
                        )

                    for pattern_str in re.findall(r'"([^"]+)"', include_text):
                        if pattern_str.startswith(("//", ":")):
                            continue
                        if "*" in pattern_str:
                            files.extend(
                                glob(os.path.join(build_dir, pattern_str), recursive=True)
                            )
                        else:
                            candidate = os.path.join(build_dir, pattern_str)
                            if os.path.isfile(candidate):
                                files.append(candidate)
                    files = [f for f in files if os.path.realpath(f) not in
                             {os.path.realpath(e) for e in excluded}]

                # dict.fromkeys: a file can match several include patterns.
                unique = list(dict.fromkeys(f for f in files if f.endswith(".swift")))
                yield module, rel_dir, unique


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    scope = args or SCAN_ROOTS

    findings = []
    modules_checked = 0

    for module, rel_dir, files in iter_modules(scope):
        if len(files) < 2:
            continue
        modules_checked += 1
        # type name -> list of files declaring it
        declarations = {}
        for path in files:
            src = strip_noise(read(path))
            local = set()
            for match in DECL_RE.finditer(src):
                line_start = src.rfind("\n", 0, match.start()) + 1
                if EXTENSION_RE.match(src, line_start):
                    continue
                if FILE_SCOPED_RE.search(match.group("modifiers")):
                    continue  # file-scoped: cannot collide across files
                local.add((match.group("kind"), match.group("name")))
            for kind, name in local:
                declarations.setdefault(name, []).append(
                    (os.path.relpath(path, REPO_ROOT), kind)
                )

        for name, sites in sorted(declarations.items()):
            if len(sites) > 1:
                findings.append((module, rel_dir, name, sites))

    if not findings:
        print(f"OK: no duplicate type declarations ({modules_checked} modules checked).")
        return 0

    print(f"FAIL: {len(findings)} duplicate declaration(s):\n")
    for module, rel_dir, name, sites in findings:
        print(f"{module} ({rel_dir}) declares '{name}' {len(sites)} times:")
        for path, kind in sites:
            print(f"    {kind} in {path}")
        print()
    return 1


if __name__ == "__main__":
    sys.exit(main())
