#!/usr/bin/env python3
"""Every architecture the build system can emit is handled everywhere it matters.

`Make.py` can emit three Apple CPUs (`arm64`, `sim_arm64`, `x86_64`), but the
tree only ever gets exercised on two of them, so the third rots quietly in four
different places at once. Building for the x86_64 simulator on an Intel host
turned up eight separate instances, none of which any existing checker sees:

  * a `select()` keyed on `ios_arm64` + `ios_sim_arm64` with no third branch and
    no `//conditions:default` — `webrtc` (twice) and `TelegramUI`. Bazel reports
    this during *analysis*, which `--keep_going` does not soften, so it costs a
    whole CI round and stops every other finding from being reported at all;
  * a genrule whose `$(TARGET_CPU)` chain falls through to `echo "Unsupported
    architecture"` — `ffmpeg`, `td`, `dav1d`. Worse than a hard failure: the
    chain does not `exit 1`, so the genrule keeps going with `BUILD_ARCH` empty
    and fails later somewhere unrelated;
  * a BUILD that maps a CPU to an arch name its own `build-*-bazel.sh` does not
    handle — `mozjpeg`. The BUILD side looks complete, which is exactly why this
    one survived: `ios_x86_64` was listed right there in the if/elif chain;
  * NEON intrinsics reached on a non-ARM target — `subcodec`, whose header
    guards `<arm_neon.h>` correctly while its .cpp includes it unconditionally.

The architecture list is read out of `Make.py` rather than hardcoded, so adding
a configuration there extends this checker with it.

    python3 build-system/merge-tools/check_arch_coverage.py
    python3 build-system/merge-tools/check_arch_coverage.py --root /tmp/tree

Exit status is 1 when anything is reported. Vendored upstream sources are
skipped for the NEON check only (see VENDORED_PREFIXES); the BUILD checks apply
everywhere, since a vendored library still needs a BUILD file that builds it.
"""

import os
import re
import sys

from buildgraph import in_reachable, reachable_directories

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Bazel `--ios_multi_cpus` value -> the config_setting labels that select it.
# A select naming any label here is an architecture select and must cover all of
# them. Both spellings of the arm64 simulator appear in the tree.
ARCH_LABELS = {
    "arm64": ("@build_bazel_rules_apple//apple:ios_arm64",),
    "sim_arm64": (
        "//build-system:ios_sim_arm64",
        "@build_bazel_rules_apple//apple:ios_sim_arm64",
    ),
    "x86_64": ("@build_bazel_rules_apple//apple:ios_x86_64",),
    "armv7": ("@build_bazel_rules_apple//apple:ios_armv7",),
}

# `$(TARGET_CPU)` spelling of the same thing, as it appears inside genrules.
TARGET_CPU_NAMES = {
    "arm64": "ios_arm64",
    "sim_arm64": "ios_sim_arm64",
    "x86_64": "ios_x86_64",
    "armv7": "ios_armv7",
}

# armv7 has not been emitted by Make.py for years; a select that omits it is not
# a finding, but one that omits an architecture Make.py can still produce is.
OPTIONAL_ARCHES = {"armv7"}

# Upstream drops whose SIMD is their own business. The NEON check skips these;
# everything else in the tree is ours to keep portable.
VENDORED_PREFIXES = (
    "third-party/webrtc/webrtc/",
    "third-party/webrtc/absl/",
    "third-party/webrtc/pffft/",
    "third-party/webrtc/crc32c/",
    "third-party/webrtc/libsrtp/",
    "third-party/boringssl/",
    "third-party/libjxl/libjxl/",
    "third-party/webp/libwebp/",
    "third-party/libvpx/libvpx/",
    "third-party/dav1d/dav1d/",
    "third-party/mozjpeg/mozjpeg/",
    "third-party/opus/opus/",
    "third-party/openh264/third_party/",
    "third-party/td/td/",
    "third-party/XcodeGen/",
    "submodules/ffmpeg/Sources/FFMpeg/ffmpeg-",
    "submodules/rlottie/rlottie/",
    "submodules/LottieCpp/lottiecpp/",
    "submodules/TgVoipWebrtc/tgcalls/",
    "Telegram/WatchApp/Packages/",
)

SOURCE_SUFFIXES = (".c", ".cc", ".cpp", ".m", ".mm", ".h", ".hpp")

SELECT_RE = re.compile(r"select\(\s*\{(.*?)\}\s*\)", re.S)
SELECT_KEY_RE = re.compile(r'"([^"]+)"\s*:')
TARGET_CPU_RE = re.compile(r'"\$\(TARGET_CPU\)"\s*==\s*"([\w]+)"')
BUILD_ARCH_RE = re.compile(r'BUILD_ARCH\s*=\s*"([^"$]+)"')
SCRIPT_RE = re.compile(r"(build-[\w-]+-bazel\.sh)")

# An ARM-only construct: the header, or an intrinsic/vector type from it.
NEON_RE = re.compile(
    r"arm_neon\.h"
    r"|\b(?:u?int|float|poly)(?:8|16|32|64)x(?:1|2|4|8|16)(?:x[234])?_t\b"
    r"|\bv(?:ld|st|dup|add|sub|mul|max|min|shl|shr|orr|and|eor|ceq|cge|cgt|get|set|mov|cvt|rev|zip|uzp|tbl|bsl|abs|neg|pad|qmov|mla|mls|maxv|minv)"
    r"[a-z0-9_]*q?_[a-z]?[su]?(?:8|16|32|64)\s*\("
)
# Guards that make an ARM-only construct legal.
NEON_GUARD_RE = re.compile(r"__ARM_NEON|__aarch64__|__arm64__|TARGET_CPU_ARM")
IF_RE = re.compile(r"^\s*#\s*if")
ELIF_RE = re.compile(r"^\s*#\s*elif")
ELSE_RE = re.compile(r"^\s*#\s*else")
ENDIF_RE = re.compile(r"^\s*#\s*endif")


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def walk(root, suffixes, skip_vendored, live=None):
    for current, dirs, files in os.walk(root):
        dirs[:] = [
            d
            for d in dirs
            if d not in (".git", "bazel-out", "build-input")
            and not d.startswith("bazel-")
        ]
        for name in files:
            full = os.path.join(current, name)
            rel = os.path.relpath(full, root)
            if skip_vendored and rel.startswith(VENDORED_PREFIXES):
                continue
            # Tests/ and exteraGram/Playground are in the tree but in nothing's
            # dependency graph; reporting them fails on findings CI cannot hit.
            if live is not None and not in_reachable(rel, live):
                continue
            if name == suffixes or name.endswith(suffixes):
                yield rel, full


def emitted_architectures(root):
    """The `--ios_multi_cpus` values Make.py can actually pass to bazel."""
    make_py = os.path.join(root, "build-system", "Make", "Make.py")
    if not os.path.isfile(make_py):
        return set(ARCH_LABELS) - OPTIONAL_ARCHES
    found = set(re.findall(r"--ios_multi_cpus=([\w,]+)", read(make_py)))
    arches = set()
    for value in found:
        arches.update(value.split(","))
    return {a for a in arches if a in ARCH_LABELS}


def check_selects(root, arches, findings, live):
    """A select keyed on one architecture must handle every architecture."""
    label_to_arch = {
        label: arch for arch, labels in ARCH_LABELS.items() for label in labels
    }
    for rel, full in walk(root, "BUILD", skip_vendored=False, live=live):
        text = read(full)
        for match in SELECT_RE.finditer(text):
            keys = SELECT_KEY_RE.findall(match.group(1))
            covered = {label_to_arch[k] for k in keys if k in label_to_arch}
            if not covered:
                continue
            if "//conditions:default" in keys:
                continue
            missing = arches - covered
            if missing:
                line = text.count("\n", 0, match.start()) + 1
                findings.append(
                    f"{rel}:{line}: select() covers {sorted(covered)} but the "
                    f"build system also emits {sorted(missing)}, and there is "
                    f"no //conditions:default — bazel fails during analysis"
                )


def check_target_cpu_chains(root, arches, findings, live):
    """A genrule's $(TARGET_CPU) chain must name every architecture."""
    expected = {TARGET_CPU_NAMES[a] for a in arches}
    for rel, full in walk(root, "BUILD", skip_vendored=False, live=live):
        text = read(full)
        named = set(TARGET_CPU_RE.findall(text))
        if not named & set(TARGET_CPU_NAMES.values()):
            continue
        missing = expected - named
        if missing:
            line = text.count("\n", 0, TARGET_CPU_RE.search(text).start()) + 1
            findings.append(
                f"{rel}:{line}: $(TARGET_CPU) chain handles {sorted(named)} but "
                f"not {sorted(missing)} — the genrule runs on with an empty "
                f"BUILD_ARCH and fails somewhere else"
            )


def check_script_arches(root, arches, findings, live):
    """Every arch name an emitted CPU maps to must exist in the build script.

    Only the names reachable from an architecture Make.py still emits: the
    `ios_armv7` arms in these chains are years dead, and their arch names are
    legitimately absent from the scripts.
    """
    wanted_cpus = {TARGET_CPU_NAMES[a] for a in arches}
    for rel, full in walk(root, "BUILD", skip_vendored=False, live=live):
        text = read(full)
        # Walk the chain in order so each "ios_x" is paired with the
        # BUILD_ARCH= assignment that follows it.
        pairs = re.findall(
            r'"\$\(TARGET_CPU\)"\s*==\s*"(\w+)".*?BUILD_ARCH\s*=\s*"([^"$]+)"',
            text,
            re.S,
        )
        live_names = {arch for cpu, arch in pairs if cpu in wanted_cpus}
        if not live_names:
            continue
        for script_name in sorted(set(SCRIPT_RE.findall(text))):
            script_path = os.path.join(root, os.path.dirname(rel), script_name)
            if not os.path.isfile(script_path):
                # ffmpeg keeps its script a few directories below its BUILD.
                matches = [p for _, p in walk(root, script_name, skip_vendored=False)]
                if len(matches) != 1:
                    continue
                script_path = matches[0]
            script = read(script_path)
            for arch in sorted(live_names):
                if not re.search(r'["\s=]' + re.escape(arch) + r'["\s\]]', script):
                    findings.append(
                        f'{rel}: passes BUILD_ARCH="{arch}" to {script_name}, '
                        f"which does not handle that name"
                    )


def check_neon_guards(root, findings, live):
    """ARM-only constructs in our own sources must sit under an ARM guard.

    Both polarities have to be tracked: subcodec's .cpp opens
    `#if !defined(__ARM_NEON)` around the portable return and puts the NEON body
    in the `#else`, so treating any line that merely mentions the macro as "now
    guarded" gets the two halves exactly backwards.
    """
    for rel, full in walk(root, SOURCE_SUFFIXES, skip_vendored=True, live=live):
        text = read(full)
        if "neon" not in text.lower() and "x16_t" not in text:
            continue
        stack = []  # one entry per open conditional: (is_arm_branch, chain_tests_arm)
        for number, line in enumerate(text.split("\n"), 1):
            if IF_RE.match(line):
                stack.append(_branch_state(line))
            elif ELIF_RE.match(line) and stack:
                is_arm, tested = _branch_state(line)
                stack[-1] = (is_arm, stack[-1][1] or tested)
            elif ELSE_RE.match(line) and stack:
                is_arm, tested = stack[-1]
                # The else of a pure ARM test flips: not-ARM becomes ARM.
                stack[-1] = ((not is_arm) if tested else False, tested)
            elif ENDIF_RE.match(line) and stack:
                stack.pop()
            elif not any(is_arm for is_arm, _ in stack) and NEON_RE.search(line):
                findings.append(
                    f"{rel}:{number}: ARM-only construct outside any "
                    f"__ARM_NEON/__aarch64__ guard: {line.strip()[:70]}"
                )
                break  # one report per file is enough to act on


def _branch_state(line):
    """(this branch is the ARM one, this line tests an ARM macro at all)."""
    if not NEON_GUARD_RE.search(line):
        return (False, False)
    negated = re.search(r"!\s*(?:defined\s*\(\s*)?(?:__ARM_NEON|__aarch64__|__arm64__)", line)
    return (not negated, True)


def main():
    root = REPO_ROOT
    if "--root" in sys.argv:
        root = os.path.abspath(sys.argv[sys.argv.index("--root") + 1])

    arches = emitted_architectures(root) - OPTIONAL_ARCHES
    live = reachable_directories(root)
    findings = []
    check_selects(root, arches, findings, live)
    check_target_cpu_chains(root, arches, findings, live)
    check_script_arches(root, arches, findings, live)
    check_neon_guards(root, findings, live)

    if findings:
        print(f"{len(findings)} architecture coverage finding(s):\n")
        for finding in findings:
            print(f"  {finding}")
        print(
            f"\nArchitectures Make.py can emit: {sorted(arches)} "
            f"(read from build-system/Make/Make.py)"
        )
        return 1

    print(
        f"OK: every BUILD select, $(TARGET_CPU) chain and build script covers "
        f"{sorted(arches)}, and no ARM-only construct is unguarded."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
