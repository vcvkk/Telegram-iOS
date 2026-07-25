#!/usr/bin/env python3
"""Cross-check `import X` statements against Bazel `deps` in BUILD files.

Catches the "no such module 'X'" class of failure before it costs a CI run.
During the 12.8 bump this bit us at least four times (EGGTranslate,
ButtonComponent, TextProcessingScreen, OpenUserGeneratedUrl): a source file
imported a module whose Bazel target was missing from the library's deps.

rules_swift propagates transitive `.swiftmodule`s on the search path, so an
`import X` compiles as long as X is reachable *anywhere* through the dependency
graph — not only as a direct dep. The check therefore walks the transitive
closure of `deps` and only reports a module that is unreachable, which is
exactly the condition that produces "no such module" at compile time. (A direct-
deps-only check would drown in false positives: e.g. WebUI legitimately imports
Postbox via TelegramCore.)

Usage:
    check_build_deps.py                # scan whole repo, exit 1 on findings
    check_build_deps.py submodules/GalleryUI
    check_build_deps.py --list-modules # dump the module -> target index
"""

import os
import re
import sys
from glob import glob

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

SCAN_ROOTS = ["submodules", "exteraGram", "Telegram", "third-party"]

# Modules provided by the toolchain / SDK rather than by a Bazel target.
SYSTEM_MODULES = {
    "Foundation", "UIKit", "Swift", "Dispatch", "CoreGraphics", "CoreMedia",
    "CoreText", "CoreLocation", "CoreImage", "CoreVideo", "CoreAudio",
    "CoreTelephony", "CoreMotion", "CoreServices", "CoreSpotlight", "CoreBluetooth",
    "CoreFoundation", "CoreData", "CoreML", "CoreNFC", "CoreHaptics",
    "AVFoundation", "AVKit", "Photos", "PhotosUI", "QuartzCore", "Metal",
    "MetalKit", "MetalPerformanceShaders", "OpenGLES", "WebKit", "SafariServices",
    "StoreKit", "PassKit", "Contacts", "ContactsUI", "MapKit", "MessageUI",
    "UserNotifications", "UserNotificationsUI", "Intents", "IntentsUI",
    "LocalAuthentication", "Security", "SystemConfiguration", "AudioToolbox",
    "VideoToolbox", "MediaPlayer", "MobileCoreServices", "ImageIO", "Accelerate",
    "SwiftUI", "Combine", "WatchKit", "WatchConnectivity", "ClockKit",
    "HealthKit", "HomeKit", "ARKit", "SceneKit", "SpriteKit", "GameController",
    "GLKit", "ReplayKit", "Network", "NetworkExtension", "PushKit", "CallKit",
    "CarPlay", "CryptoKit", "NaturalLanguage", "Vision", "Speech", "SoundAnalysis",
    "BackgroundTasks", "LinkPresentation", "UniformTypeIdentifiers", "OSLog",
    "os", "simd", "Darwin", "ObjectiveC", "MachO", "XCTest", "Compression",
    "AuthenticationServices", "AdSupport", "AppTrackingTransparency",
    "DeviceCheck", "FileProvider", "QuickLook", "PDFKit", "PencilKit",
    "SwiftUICore", "Observation", "Testing", "TabularData", "Charts",
    "ActivityKit", "WidgetKit", "AppIntents", "TipKit", "Translation",
    "FoundationModels", "GroupActivities", "ManagedSettings", "MetricKit",
}

# Rules that define an importable Swift/ObjC module.
MODULE_RULE_RE = re.compile(
    r"(?P<rule>swift_library|objc_library|apple_static_framework_import|"
    r"objc_import|cc_library)\(\s*(?P<body>.*?)\n\)",
    re.S,
)
NAME_RE = re.compile(r'\bname\s*=\s*"([^"]+)"')
MODULE_NAME_RE = re.compile(r'\bmodule_name\s*=\s*"([^"]+)"')
# `import Foo`, `@_implementationOnly import Foo`, `import class Foo.Bar`
IMPORT_RE = re.compile(
    r"^\s*(?:@[\w_]+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|"
    r"func|var|let)\s+)?([A-Za-z_][\w]*)",
    re.M,
)
LABEL_RE = re.compile(r'"(//[^"]+|:[^"]+)"')
# Simple top-level list assignment, e.g. `egdeps = [ "//a:b" ]`
VAR_ASSIGN_RE = re.compile(r"^(\w+)\s*=\s*\[(.*?)\]", re.S | re.M)


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def strip_build_comments(text):
    """Drop `#` comments from a BUILD file.

    Several BUILD files keep deps commented out (e.g. Utils/DeviceModel has
    "# MARK: exteraGram" followed by commented-out AccountContext). Parsing
    those as real edges invents dependency cycles that Bazel never sees.
    """
    out = []
    for line in text.split("\n"):
        in_string = False
        quote = ""
        for i, ch in enumerate(line):
            if in_string:
                if ch == quote and line[i - 1 : i] != "\\":
                    in_string = False
            elif ch in "\"'":
                in_string, quote = True, ch
            elif ch == "#":
                line = line[:i]
                break
        out.append(line)
    return "\n".join(out)


def canonical(label, rel_dir=None):
    """Normalize a label to //path:target form."""
    if label.startswith(":"):
        label = f"//{rel_dir}{label}"
    if label.startswith("//") and ":" not in label[2:]:
        label = f"{label}:{os.path.basename(label[2:])}"
    return label


def build_graph():
    """Return (module -> canonical label, label -> set(dep labels))."""
    module_of_label = {}
    deps_of_label = {}
    for build_path in glob(os.path.join(REPO_ROOT, "**", "BUILD"), recursive=True):
        rel_dir = os.path.relpath(os.path.dirname(build_path), REPO_ROOT)
        if rel_dir.startswith("bazel-") or "/bazel-" in rel_dir:
            continue
        src = strip_build_comments(read(build_path))
        for match in MODULE_RULE_RE.finditer(src):
            body = match.group("body")
            name_match = NAME_RE.search(body)
            if not name_match:
                continue
            target = name_match.group(1)
            label = canonical(f"//{rel_dir}:{target}")
            module_match = MODULE_NAME_RE.search(body)
            module_of_label[label] = module_match.group(1) if module_match else target
            deps_of_label[label] = {
                canonical(d, rel_dir) for d in resolve_deps(body, src, rel_dir)
            }
    return module_of_label, deps_of_label


def find_cycle(deps_of_label):
    """Return one dependency cycle as a list of labels, or None.

    Bazel only reports this during analysis, which costs a CI run (and it
    reports a single cycle at a time). It happened when a dep was added to
    GalleryUI that upstream deliberately avoids by routing through
    sharedContext.makeTextProcessingScreen instead of importing the module.
    """
    WHITE, GREY, BLACK = 0, 1, 2
    color = {}
    stack = []

    def visit(label):
        color[label] = GREY
        stack.append(label)
        for dep in sorted(deps_of_label.get(label, ())):
            if dep not in deps_of_label:
                continue  # external / non-swift target
            state = color.get(dep, WHITE)
            if state == GREY:
                return stack[stack.index(dep):] + [dep]
            if state == WHITE:
                found = visit(dep)
                if found:
                    return found
        stack.pop()
        color[label] = BLACK
        return None

    sys.setrecursionlimit(10000)
    for label in sorted(deps_of_label):
        if color.get(label, WHITE) == WHITE:
            found = visit(label)
            if found:
                return found
    return None


def reachable_modules(label, module_of_label, deps_of_label):
    """Modules importable from `label` = its own plus the transitive closure."""
    seen = set()
    stack = [label]
    modules = set()
    while stack:
        current = stack.pop()
        if current in seen:
            continue
        seen.add(current)
        if current in module_of_label:
            modules.add(module_of_label[current])
        stack.extend(deps_of_label.get(current, ()))
    return modules


def resolve_deps(body, build_src, rel_dir):
    """Collect dep labels, expanding simple list variables used in the body."""
    labels = set()
    deps_match = re.search(
        r"\bdeps\s*=\s*(.*?)(?:\n\s{4}\w+\s*=|\n\s*\)\s*,?\s*$|\Z)", body, re.S | re.M
    )
    deps_text = deps_match.group(1) if deps_match else ""

    for raw in LABEL_RE.findall(deps_text):
        labels.add(raw if raw.startswith("//") else f"//{rel_dir}{raw}")

    # `deps = egdeps + [...]` — pull in labels from referenced variables.
    for var in re.findall(r"\b([a-z_]\w*)\b", deps_text):
        for assign in VAR_ASSIGN_RE.finditer(build_src):
            if assign.group(1) != var:
                continue
            for raw in LABEL_RE.findall(assign.group(2)):
                labels.add(raw if raw.startswith("//") else f"//{rel_dir}{raw}")
    return labels


def expand_srcs(body, build_dir):
    """Resolve srcs globs / explicit lists to concrete source files."""
    files = []
    srcs_match = re.search(r"\bsrcs\s*=\s*(.*?)(?:\n\s{4}\w+\s*=|\n\)|\Z)", body, re.S)
    if not srcs_match:
        return files
    srcs_text = srcs_match.group(1)

    for pattern in re.findall(r'"([^"]+)"', srcs_text):
        if pattern.startswith("//") or pattern.startswith(":"):
            continue  # label, not a path
        if "*" in pattern:
            files.extend(glob(os.path.join(build_dir, pattern), recursive=True))
        else:
            candidate = os.path.join(build_dir, pattern)
            if os.path.isfile(candidate):
                files.append(candidate)
    return [f for f in files if f.endswith((".swift", ".m", ".mm"))]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    module_of_label, deps_of_label = build_graph()
    # module -> labels providing it (for the "add to deps" suggestion)
    providers = {}
    for label, module in module_of_label.items():
        providers.setdefault(module, set()).add(label)

    if "--list-modules" in sys.argv:
        for module in sorted(providers):
            print(f"{module}: {' '.join(sorted(providers[module]))}")
        return 0

    # Cheap and always worth doing: a cycle fails the whole build at analysis
    # time, before a single file is compiled.
    cycle = find_cycle(deps_of_label)
    if cycle:
        print("FAIL: dependency cycle in the build graph:\n")
        for label in cycle:
            print(f"    {label}")
        print("\nUpstream usually breaks such a cycle with a factory method on"
              "\nSharedAccountContext instead of a direct module dependency.")
        return 1

    scope = args or SCAN_ROOTS
    findings = []
    checked = 0
    closure_cache = {}

    for root in scope:
        pattern = os.path.join(REPO_ROOT, root, "**", "BUILD")
        for build_path in glob(pattern, recursive=True):
            rel_dir = os.path.relpath(os.path.dirname(build_path), REPO_ROOT)
            if rel_dir.startswith("bazel-") or "/bazel-" in rel_dir:
                continue
            build_src = strip_build_comments(read(build_path))
            for match in re.finditer(r"swift_library\(\s*(.*?)\n\)", build_src, re.S):
                body = match.group(1)
                name_match = NAME_RE.search(body)
                if not name_match:
                    continue
                target = name_match.group(1)
                label = canonical(f"//{rel_dir}:{target}")
                if label not in closure_cache:
                    closure_cache[label] = reachable_modules(
                        label, module_of_label, deps_of_label
                    )
                available = closure_cache[label]

                for src_file in expand_srcs(body, os.path.dirname(build_path)):
                    checked += 1
                    for module in set(IMPORT_RE.findall(read(src_file))):
                        if module in SYSTEM_MODULES or module in available:
                            continue
                        if module not in providers:
                            continue  # unknown module: not a missing-dep signal
                        findings.append((
                            os.path.relpath(src_file, REPO_ROOT),
                            module,
                            label,
                            sorted(providers[module])[0],
                        ))

    if not findings:
        print(f"OK: no missing deps ({checked} source files checked).")
        return 0

    print(f"FAIL: {len(findings)} import(s) without a matching dep:\n")
    grouped = {}
    for src_file, module, target, suggestion in findings:
        grouped.setdefault((target, module, suggestion), []).append(src_file)
    for (target, module, suggestion), files in sorted(grouped.items()):
        print(f"{target} imports {module} but does not depend on it")
        print(f"    add to deps: \"{suggestion}\"")
        for src_file in sorted(files)[:3]:
            print(f"    used in: {src_file}")
        if len(files) > 3:
            print(f"    ... and {len(files) - 3} more file(s)")
        print()
    return 1


if __name__ == "__main__":
    sys.exit(main())
