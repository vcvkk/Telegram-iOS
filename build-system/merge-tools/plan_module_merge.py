#!/usr/bin/env python3
"""Verify the Android-parity module layout before a single file is moved.

The fork keeps 56 flat directories under `exteraGram/`. The plan is to turn them
into `exteraGram/messenger/<package>/`, mirroring the Android package tree, and
to merge the fine-grained Swift modules into one module per package.

Merging modules is the operation that turns a valid dependency chain into a
cycle: if `A -> X -> B` and A and B are folded into one node, that node now
depends on X and X depends on it. Bazel reports a cycle only during analysis,
which `--keep_going` does not soften and which costs a full CI round. The same
merge also drops the module boundary between the folded units, so two types that
legally shared a name in different modules become an invalid redeclaration.

Both are cheap to compute and expensive to discover from CI, so the layout is
checked here first. Nothing in this file writes to the tree.

Checks, in the order they are reported:

  1. classification  - which directories can actually be folded into a
                       swift_library, and which only move (filegroups compile
                       into a *host* module through `egsrcs`, and cannot)
  2. coverage        - every directory is assigned, excluded, or reported
  3. module names    - the new lower-case module names do not collide with a
                       module that already exists in the tree
  4. cycles          - the whole-repo dependency graph with each group
                       contracted into one node, reported down to the original
                       labels that produce each edge
  5. redeclarations  - top-level names declared in two members of one group
  6. imports         - intra-group imports that become redundant, files that
                       would end up with the same import twice, and the
                       external files that need their import renamed
  7. order           - leaf-first order to apply the groups in
  8. aliases         - how many external BUILD references each old label has

Usage:
    plan_module_merge.py                  # check the built-in layout
    plan_module_merge.py --suggest        # on a cycle, compute a layout without one
    plan_module_merge.py --layout x.json  # check an alternative grouping
    plan_module_merge.py --dump-layout    # print the built-in layout as JSON
    plan_module_merge.py --verbose        # include the per-group detail

Exit code 0 means the layout can be applied as-is.
"""

import json
import os
import re
import sys
from collections import defaultdict
from glob import glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check_build_deps as cbd
import check_duplicate_types as cdt

REPO_ROOT = cbd.REPO_ROOT
EG_ROOT = "exteraGram"
EG_DIR = os.path.join(REPO_ROOT, EG_ROOT)

# Swift module -> exteraGram directories that fold into it.
#
# The 25 Android packages are: adblock, ai, api, backup, badges, camera,
# components, config, debug, drawer, export, feed, forward, icons, maps.yandex,
# nowplaying, pillstack, plugins, preferences, proxy, regdate, speech,
# translators, updater, utils. Thirteen of them have no iOS counterpart and get
# no placeholder directory. Seven modules below have no Android counterpart and
# are created rather than dumped into `utils`.
#
# `config` and `regdate` carry two modules each, not one. The draft plan asked
# for exactly one module per package; check 4 showed that is not achievable for
# those two, because each holds members on both sides of TelegramCore:
#
#   TelegramCore  ->  EGSimpleSettings / EGConfig / EG*Scheme      (below)
#   EGGHSettings / EGRegDate  ->  AccountContext  ->  TelegramCore (above)
#
# Folding both sides into one module puts TelegramCore on a path between two
# members of that module, which is exactly a Bazel analysis-time cycle. The
# `*core` module holds the lower layer. `--suggest` recomputes this split, and
# then coarsens it back to the fewest modules that stay acyclic; that is where
# this list came from. The split is at the *module* level only — both modules
# of a package live in one `exteraGram/messenger/<package>/` directory, so the
# tree a user browses still matches Android one-to-one.
LAYOUT = {
    # --- packages that exist on Android ---
    "api": [
        "EGAPI", "EGAPIToken", "EGAPIWebSettings",
        "EGDeviceToken", "EGRecentSessionApiId",
    ],
    # `RegDate` is a bare Codable DTO, which on Android lives in api/dto, not in
    # the regdate package — that only holds RegDateController. It cannot join
    # `api` as one module: TelegramCore depends on it while EGAPIToken depends
    # on TelegramCore, so it takes the lower module of the `api` package.
    "apicore": ["EGRegDateScheme"],
    "config": ["EGGHSettings", "EGWebSettings"],
    "configcore": [
        "EGSimpleSettings", "EGConfig", "EGGHSettingsScheme",
        "EGWebSettingsScheme", "EGAppGroupIdentifier",
    ],
    "preferences": ["EGSettingsUI", "EGItemListUI", "EGSettingsBundle"],
    "plugins": ["EGPluginEngine"],
    "translators": ["EGGTranslate", "EGTranslationLangFix"],
    "badges": ["EGBadges", "EGAppBadgeAssets", "EGAppBadgeOffset"],
    "debug": ["EGDebugUI", "EGShowMessageJson", "EGDBReset", "FLEX"],
    "regdate": ["EGRegDate"],
    # `EGSwiftUI` looks like utils/ui on Android, but moving it there is a
    # cycle: it sits above EGGTranslate and EGStatus while SwiftSoup sits below
    # them, and `utils` cannot hold both. It stays a component.
    "components": ["EGInputToolbar", "EGSwiftUI", "EGNY"],
    "utils": [
        # EGRequests is requestsGet/requestsDownload/requestsCustom — the
        # generic HTTP helper, which Android keeps in utils/network. Only the
        # API-specific client lives in the api package.
        "EGRequests",
        "EGSwiftSignalKit", "Wrap", "SwiftSoup", "SFSafariViewControllerPlus",
        "EGKeychainBackupManager", "EGActionRequestHandlerSanitizer",
        "EGContentAnalysis", "EGTabBarHeightModifier",
        "EGEmojiKeyboardDefaultFirst", "EGIQTP", "EGExternalVideoPlayer",
        "EGDoubleTapMessageAction", "EGChatListSimpleSettingsSignal",
        "EGSharedAccountContextMigration", "ChatControllerImplExtension",
    ],
    # --- no Android counterpart; created rather than folded into utils ---
    "logging": ["EGLogging", "EGLoggingComposer"],
    "strings": ["EGStrings"],
    "iap": ["EGIAP"],
    "paywall": ["EGPayWall"],
    "pro": ["EGProUI"],
    "status": ["EGStatus"],
    "webapp": ["EGWebAppExtensions"],
}

# Modules that share a package directory with another module. The directory
# tree is what mirrors Android; the module split is an iOS build constraint and
# must not show up as an extra package.
PACKAGE_OF = {
    "configcore": "config",
    "apicore": "api",
}


def package_of(module):
    return PACKAGE_OF.get(module, module)

# Directories that stay where they are. `Playground` is a separate app target;
# `FixConcurrencyBackport` is a patch plus a BUILD file, not a module.
EXCLUDED = {"Playground", "FixConcurrencyBackport"}

# Directories that move but need work no other directory needs. Without this
# the scanner just says "no target found — check it by hand", which is where a
# move quietly loses a file.
SPECIAL_CASES = {
    "FLEX": "empty BUILD plus FLEX.BUILD, the build file for an external "
            "repository. Moving it means editing the `build_file = "
            "\"@//exteraGram/FLEX:FLEX.BUILD\"` line in MODULE.bazel too.",
}

# Rules that produce something a group has to account for.
SWIFT_RULES = {"swift_library"}
NON_MERGEABLE_RULES = {
    "objc_library", "filegroup", "apple_bundle_import", "cc_library",
    "objc_import", "apple_static_framework_import", "ios_application",
    "swift_binary", "genrule", "apple_resource_bundle",
}
KNOWN_RULES = SWIFT_RULES | NON_MERGEABLE_RULES

# Anchored on the known rule names rather than on `\w+(`: a bare `\w+(` also
# matches the `load("...", "swift_library")` line that opens every BUILD file,
# and because `finditer` does not backtrack into a match it already consumed,
# that one `load(` swallowed the swift_library underneath it.
RULE_RE = re.compile(
    r"^(?P<rule>"
    + "|".join(sorted(KNOWN_RULES, key=len, reverse=True))
    + r")\(\s*(?P<body>.*?)\n\)",
    re.S | re.M,
)
# Top-level `let`/`var`/`typealias` collide on the name alone once the module
# boundary is gone. `func` overloads on its signature, so it is advisory only.
TOPLEVEL_VALUE_RE = re.compile(
    r"^(?:public\s+|internal\s+|open\s+|final\s+|@\w+\s+)*"
    r"(?P<kind>let|var|typealias)\s+(?P<name>[A-Za-z_]\w*)",
    re.M,
)
TOPLEVEL_FUNC_RE = re.compile(
    r"^(?:public\s+|internal\s+|open\s+|final\s+|@\w+\s+)*"
    r"func\s+(?P<name>[A-Za-z_]\w*)",
    re.M,
)


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


# --------------------------------------------------------------------------
# BUILD inventory
# --------------------------------------------------------------------------

class Target:
    __slots__ = ("rule", "name", "module_name", "label", "rel_dir", "srcs", "directory")

    def __init__(self, rule, name, module_name, label, rel_dir, srcs, directory):
        self.rule = rule
        self.name = name
        self.module_name = module_name
        self.label = label
        self.rel_dir = rel_dir
        self.srcs = srcs
        self.directory = directory

    def __repr__(self):
        return f"<{self.rule} {self.label}>"


def expand_srcs(body, build_dir, filegroup_files):
    """Resolve a `srcs` attribute to concrete files.

    Handles `glob([...], exclude = [...])`, explicit paths, and label entries.
    A label entry is how `egsrcs` works: the referenced filegroup's sources are
    compiled into *this* module, so they have to be followed.
    """
    srcs_match = re.search(
        r"\bsrcs\s*=\s*(.*?)(?:\n\s{4}\w+\s*=|\n\s*\)\s*,?\s*$|\Z)",
        body, re.S | re.M,
    )
    if not srcs_match:
        return [], []
    srcs_text = srcs_match.group(1)

    exclude_match = re.search(r"exclude\s*=\s*\[(.*?)\]", srcs_text, re.S)
    exclude_patterns = (
        re.findall(r'"([^"]+)"', exclude_match.group(1)) if exclude_match else []
    )
    include_text = srcs_text[: exclude_match.start()] if exclude_match else srcs_text

    excluded = set()
    for pattern in exclude_patterns:
        excluded.update(
            os.path.realpath(p)
            for p in glob(os.path.join(build_dir, pattern), recursive=True)
        )

    files, labels = [], []
    for entry in re.findall(r'"([^"]+)"', include_text):
        if entry.startswith(("//", ":", "@")):
            labels.append(entry)
            files.extend(filegroup_files.get(cbd.canonical(entry), []))
            continue
        if "*" in entry:
            files.extend(glob(os.path.join(build_dir, entry), recursive=True))
        else:
            candidate = os.path.join(build_dir, entry)
            if os.path.isfile(candidate):
                files.append(candidate)

    files = [f for f in files if os.path.realpath(f) not in excluded]
    # A file can match several include patterns.
    return list(dict.fromkeys(files)), labels


def scan_build(build_path, filegroup_files):
    """Yield every recognised rule in one BUILD file."""
    build_dir = os.path.dirname(build_path)
    rel_dir = os.path.relpath(build_dir, REPO_ROOT)
    src = cbd.strip_build_comments(read(build_path))
    for match in RULE_RE.finditer(src):
        rule = match.group("rule")
        if rule not in KNOWN_RULES:
            continue
        body = match.group("body")
        name_match = cbd.NAME_RE.search(body)
        if not name_match:
            continue
        name = name_match.group(1)
        module_match = cbd.MODULE_NAME_RE.search(body)
        module_name = module_match.group(1) if module_match else name
        files, _ = expand_srcs(body, build_dir, filegroup_files)
        yield Target(
            rule=rule,
            name=name,
            module_name=module_name if rule in SWIFT_RULES else None,
            label=cbd.canonical(f"//{rel_dir}:{name}"),
            rel_dir=rel_dir,
            srcs=files,
            directory=rel_dir.split("/")[1] if rel_dir.startswith(EG_ROOT + "/") else None,
        )


def all_build_files():
    for build_path in glob(os.path.join(REPO_ROOT, "**", "BUILD"), recursive=True):
        rel_dir = os.path.relpath(os.path.dirname(build_path), REPO_ROOT)
        if rel_dir.startswith("bazel-") or "/bazel-" in rel_dir:
            continue
        yield build_path


def inventory():
    """Return (targets by label, filegroup label -> files).

    Two passes: filegroups first, because a `swift_library` that lists a
    filegroup label in `srcs` needs that filegroup already resolved.
    """
    filegroup_files = {}
    for build_path in all_build_files():
        for target in scan_build(build_path, {}):
            if target.rule in ("filegroup", "apple_bundle_import"):
                filegroup_files[target.label] = target.srcs

    targets = {}
    for build_path in all_build_files():
        for target in scan_build(build_path, filegroup_files):
            targets[target.label] = target
    return targets, filegroup_files


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def eg_directories():
    return sorted(
        d for d in os.listdir(EG_DIR) if os.path.isdir(os.path.join(EG_DIR, d))
    )


def check_coverage(layout, directories, findings):
    assigned = {}
    for group, members in sorted(layout.items()):
        for member in members:
            if member in assigned:
                findings.append(
                    f"'{member}' is claimed by both '{assigned[member]}' and '{group}'"
                )
            assigned[member] = group
        if not re.fullmatch(r"[a-z][a-z0-9_]*", group):
            findings.append(
                f"group name '{group}' is not a valid Swift module identifier"
            )

    known = set(assigned) | EXCLUDED
    for directory in directories:
        if directory not in known:
            findings.append(
                f"'{EG_ROOT}/{directory}' is in neither the layout nor EXCLUDED"
            )
    for member in sorted(assigned):
        if member not in directories:
            findings.append(
                f"layout names '{member}', which does not exist under {EG_ROOT}/"
            )
    return assigned


def classify(layout, targets):
    """group -> {'merge': [Target], 'move': [Target], 'empty': [dir]}."""
    by_directory = defaultdict(list)
    for target in targets.values():
        if target.directory:
            by_directory[target.directory].append(target)

    result = {}
    for group, members in layout.items():
        merge, move, empty = [], [], []
        for member in members:
            member_targets = by_directory.get(member, [])
            if not member_targets:
                empty.append(member)
                continue
            for target in member_targets:
                (merge if target.rule in SWIFT_RULES else move).append(target)
        result[group] = {"merge": merge, "move": move, "empty": empty}
    return result


def check_module_names(layout, targets, findings):
    """A new lower-case module name must not already be taken."""
    existing = defaultdict(set)
    moving = {
        target.module_name
        for target in targets.values()
        if target.directory and target.module_name
    }
    for target in targets.values():
        if target.module_name and target.module_name not in moving:
            existing[target.module_name.lower()].add(target.label)

    for group in sorted(layout):
        clash = existing.get(group.lower())
        if clash:
            findings.append(
                f"new module '{group}' collides with an existing module: "
                + ", ".join(sorted(clash))
            )


def contract(deps_of_label, group_of_label):
    """Collapse every grouped label into its group node.

    Self-edges are dropped: an edge between two members of one group is exactly
    what the merge is supposed to remove. Everything that survives is a real
    edge of the merged graph.
    """
    contracted = defaultdict(set)
    # Which original edges produce each contracted edge — the cycle report is
    # useless without this.
    provenance = defaultdict(list)
    for label in deps_of_label:
        contracted.setdefault(group_of_label.get(label, label), set())
    for label, deps in deps_of_label.items():
        source = group_of_label.get(label, label)
        for dep in deps:
            target = group_of_label.get(dep, dep)
            if target == source:
                continue
            contracted[source].add(target)
            provenance[(source, target)].append((label, dep))
    return contracted, provenance


def strongly_connected(graph):
    """Every strongly connected component, via an iterative Tarjan.

    `find_cycle()` in check_build_deps returns one cycle, which is the right
    shape when a cycle is a bug to fix. Here a bad grouping usually produces
    several at once, and finding them one CI-free run at a time is still one
    edit-and-rerun cycle each, so report all of them together.
    """
    index_of = {}
    low = {}
    on_stack = set()
    stack = []
    result = []
    counter = [0]

    for root in sorted(graph):
        if root in index_of:
            continue
        work = [(root, iter(sorted(graph.get(root, ()))))]
        index_of[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            node, children = work[-1]
            advanced = False
            for child in children:
                if child not in graph:
                    continue  # external / non-module target
                if child not in index_of:
                    index_of[child] = low[child] = counter[0]
                    counter[0] += 1
                    stack.append(child)
                    on_stack.add(child)
                    work.append((child, iter(sorted(graph.get(child, ())))))
                    advanced = True
                    break
                if child in on_stack:
                    low[node] = min(low[node], index_of[child])
            if advanced:
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[node])
            if low[node] == index_of[node]:
                component = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    component.append(member)
                    if member == node:
                        break
                result.append(component)
    return result


def transitive_closure(deps_of_label):
    """label -> frozenset of labels reachable from it.

    Memoised DFS with a grey guard, so it also terminates on the (already
    reported) case where the pre-merge graph is itself cyclic.
    """
    closure = {}
    grey = set()

    def visit(label):
        if label in closure:
            return closure[label]
        if label in grey:
            return set()
        grey.add(label)
        reached = set()
        for dep in deps_of_label.get(label, ()):
            reached.add(dep)
            if dep in deps_of_label:
                reached |= visit(dep)
        grey.discard(label)
        closure[label] = reached
        return reached

    sys.setrecursionlimit(20000)
    for label in deps_of_label:
        visit(label)
    return closure


def diagnose_component(component, layout, members_of_group, closure, provenance):
    """Explain a bad component and say which members have to be split apart.

    A group is in a cycle because some of its members sit *above* the rest of
    the component in the dependency graph and others sit *below* it. Those two
    sets cannot share a module, and naming them is the whole point: the fix is
    a split, and this says exactly where.
    """
    lines = []
    component_set = set(component)
    outside_labels = set()
    for node in component:
        if node in layout:
            continue
        outside_labels.add(node)

    lines.append("    component:")
    for node in sorted(component):
        kind = "group" if node in layout else "target"
        lines.append(f"        [{kind}] {node}")

    for group in sorted(n for n in component if n in layout):
        others = outside_labels | {
            label
            for other in component_set - {group}
            if other in layout
            for label in members_of_group.get(other, ())
        }
        above, below, both = [], [], []
        for member in sorted(members_of_group.get(group, ())):
            depends_on_others = bool(closure.get(member, set()) & others)
            depended_on = any(member in closure.get(other, set()) for other in others)
            if depends_on_others and depended_on:
                both.append(member)
            elif depends_on_others:
                above.append(member)
            elif depended_on:
                below.append(member)
        lines.append(f"    group '{group}' spans both sides of this component:")
        for member in above:
            reached = sorted(closure.get(member, set()) & others)[:2]
            lines.append(f"        above  {member}  -> {', '.join(reached)}")
        for member in below:
            pullers = sorted(o for o in others if member in closure.get(o, set()))[:2]
            lines.append(f"        below  {member}  <- {', '.join(pullers)}")
        for member in both:
            lines.append(f"        spans {member}")
        if above and below:
            lines.append(f"        fix: '{group}' cannot hold the 'above' and the"
                         f" 'below' members at once; split it.")
        elif len(members_of_group.get(group, ())) == 1:
            lines.append(f"        (single module — dragged in by the other"
                         f" group(s) in this component, not a cause)")
    return lines


def refine_layout(layout, classified, deps_of_label, closure):
    """Split groups until the contracted graph is acyclic.

    A grouping is safe exactly when every group is *convex* in the dependency
    DAG: no node outside the group sits on a path between two of its members.
    Splitting a group along that boundary strictly shrinks the offending part,
    and singletons are always convex (the pre-merge graph is acyclic), so the
    loop terminates.

    Returns (parts, rounds) where parts is a list of (group, [labels]).
    """
    parts = []
    for group in sorted(layout):
        members = sorted(t.label for t in classified[group]["merge"])
        if members:
            parts.append([group, members])

    for round_number in range(1, 64):
        group_of_label = {}
        for index, (_, members) in enumerate(parts):
            for label in members:
                group_of_label[label] = f"#part{index}"
        contracted, _ = contract(deps_of_label, group_of_label)
        bad = [c for c in strongly_connected(contracted) if len(c) > 1]
        if not bad:
            return parts, round_number - 1

        split_happened = False
        for component in bad:
            component_labels = set()
            for node in component:
                if node.startswith("#part"):
                    component_labels.update(parts[int(node[5:])][1])
                else:
                    component_labels.add(node)
            for index, (group, members) in enumerate(parts):
                if f"#part{index}" not in component or len(members) < 2:
                    continue
                others = component_labels - set(members)
                above, below, spans, rest = [], [], [], []
                for member in members:
                    up = bool(closure.get(member, set()) & others)
                    down = any(member in closure.get(o, set()) for o in others)
                    (spans if up and down else
                     above if up else
                     below if down else rest).append(member)
                buckets = [b for b in (above, below, rest) if b]
                buckets.extend([m] for m in spans)
                if len(buckets) < 2:
                    continue
                parts[index] = [group, buckets[0]]
                for extra in buckets[1:]:
                    parts.append([group, extra])
                split_happened = True
                break
            if split_happened:
                break
        if not split_happened:
            return parts, -1
    return parts, -1


def is_acyclic(parts, deps_of_label):
    group_of_label = {}
    for index, (_, members) in enumerate(parts):
        for label in members:
            group_of_label[label] = f"#part{index}"
    contracted, _ = contract(deps_of_label, group_of_label)
    return not any(len(c) > 1 for c in strongly_connected(contracted))


def coarsen(parts, deps_of_label):
    """Merge split parts back together while the graph stays acyclic.

    The splitter is greedy and stops at the first partition that works, which
    over-splits: it broke `api` into three when two suffice. Every extra module
    is an extra alias, an extra BUILD file and an extra import to rewrite, so
    walk it back to the coarsest partition that is still acyclic.
    """
    parts = [list(p) for p in parts]
    changed = True
    while changed:
        changed = False
        for i in range(len(parts)):
            for j in range(i + 1, len(parts)):
                if parts[i][0] != parts[j][0]:
                    continue
                candidate = [list(p) for p in parts]
                candidate[i][1] = sorted(set(candidate[i][1]) | set(candidate[j][1]))
                del candidate[j]
                if is_acyclic(candidate, deps_of_label):
                    parts = candidate
                    changed = True
                    break
            if changed:
                break
    return parts


def name_parts(parts, closure):
    """Give each part of a split group a distinct module name, low layer first."""
    by_group = defaultdict(list)
    for group, members in parts:
        by_group[group].append(members)

    named = {}
    for group, buckets in by_group.items():
        if len(buckets) == 1:
            named[group] = sorted(buckets[0])
            continue
        # Order low-to-high: a bucket that others depend on comes first.
        def depth(bucket):
            return max(len(closure.get(label, ())) for label in bucket)
        buckets.sort(key=depth)
        for index, bucket in enumerate(buckets):
            suffix = "core" if index == 0 else ("" if index == len(buckets) - 1
                                                else f"mid{index}")
            named[f"{group}{suffix}"] = sorted(bucket)
    return named


def group_declarations(members):
    """name -> [(label, file, kind)] for every top-level declaration."""
    declarations = defaultdict(list)
    functions = defaultdict(set)
    for target in members:
        for path in target.srcs:
            if not path.endswith(".swift"):
                continue
            src = cdt.strip_noise(read(path))
            local = set()
            for match in cdt.DECL_RE.finditer(src):
                line_start = src.rfind("\n", 0, match.start()) + 1
                if cdt.EXTENSION_RE.match(src, line_start):
                    continue
                if cdt.FILE_SCOPED_RE.search(match.group("modifiers")):
                    continue
                local.add((match.group("kind"), match.group("name")))
            for match in TOPLEVEL_VALUE_RE.finditer(src):
                local.add((match.group("kind"), match.group("name")))
            for kind, name in local:
                declarations[name].append(
                    (target.label, os.path.relpath(path, REPO_ROOT), kind)
                )
            for match in TOPLEVEL_FUNC_RE.finditer(src):
                functions[match.group("name")].add(target.label)
    return declarations, functions


def check_redeclarations(classified, findings, advisories):
    for group in sorted(classified):
        members = classified[group]["merge"]
        if len(members) < 2:
            continue
        declarations, functions = group_declarations(members)
        for name, sites in sorted(declarations.items()):
            distinct = {label for label, _, _ in sites}
            if len(distinct) > 1:
                detail = "; ".join(
                    f"{kind} in {path}" for _, path, kind in sorted(sites, key=lambda s: s[1])
                )
                findings.append(
                    f"group '{group}' would redeclare '{name}' — {detail}"
                )
        for name, labels in sorted(functions.items()):
            if len(labels) > 1:
                advisories.append(
                    f"group '{group}': top-level func '{name}' comes from "
                    + ", ".join(sorted(labels))
                    + " (legal if the signatures differ)"
                )


def check_imports(classified, targets, layout):
    """Return per-group import work: redundant, duplicated, external."""
    module_to_group = {}
    for group, buckets in classified.items():
        for target in buckets["merge"]:
            if target.module_name:
                module_to_group[target.module_name] = group

    grouped_files = set()
    for buckets in classified.values():
        for target in buckets["merge"]:
            grouped_files.update(target.srcs)

    report = {group: {"redundant": 0, "duplicated": [], "files": 0} for group in layout}
    external = defaultdict(set)

    for target in targets.values():
        if target.rule not in SWIFT_RULES:
            continue
        for path in target.srcs:
            if not path.endswith(".swift"):
                continue
            imports = set(cbd.IMPORT_RE.findall(read(path)))
            touched = {
                module_to_group[module] for module in imports if module in module_to_group
            }
            if not touched:
                continue
            own_group = None
            if path in grouped_files:
                own_group = module_to_group.get(target.module_name)
            for group in touched:
                if group == own_group:
                    same = [m for m in imports if module_to_group.get(m) == group]
                    report[group]["redundant"] += len(same)
                    report[group]["files"] += 1
                else:
                    same = [m for m in imports if module_to_group.get(m) == group]
                    if len(same) > 1:
                        report[group]["duplicated"].append(
                            (os.path.relpath(path, REPO_ROOT), sorted(same))
                        )
                    external[group].add(os.path.relpath(path, REPO_ROOT))
    return report, external


def leaf_first_order(classified, contracted, layout):
    """Groups in dependency order: a group comes after everything it needs."""
    group_deps = {group: set() for group in layout}
    for group in layout:
        for dep in contracted.get(group, ()):
            if dep in group_deps and dep != group:
                group_deps[group].add(dep)

    order, placed = [], set()
    remaining = dict(group_deps)
    while remaining:
        ready = sorted(g for g, d in remaining.items() if d <= placed)
        if not ready:
            # Cycle among groups; check 4 has already reported it.
            return order, sorted(remaining)
        for group in ready:
            order.append(group)
            placed.add(group)
            del remaining[group]
    return order, []


def alias_census():
    """old label -> number of references from BUILD files outside exteraGram/."""
    counts = defaultdict(int)
    files = defaultdict(set)
    pattern = re.compile(r'"(//exteraGram/[^"]+)"')
    for build_path in all_build_files():
        rel = os.path.relpath(build_path, REPO_ROOT)
        if rel.startswith(EG_ROOT + "/"):
            continue
        for label in pattern.findall(cbd.strip_build_comments(read(build_path))):
            counts[cbd.canonical(label)] += 1
            files[cbd.canonical(label)].add(rel)
    return counts, files


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    argv = sys.argv[1:]
    if "--dump-layout" in argv:
        print(json.dumps(LAYOUT, indent=2, sort_keys=True))
        return 0
    verbose = "--verbose" in argv or "-v" in argv

    layout = LAYOUT
    if "--layout" in argv:
        layout_path = argv[argv.index("--layout") + 1]
        layout = json.loads(read(layout_path))

    findings = []      # blocking
    advisories = []    # worth reading, not blocking

    directories = eg_directories()
    targets, _ = inventory()
    module_of_label, deps_of_label = cbd.build_graph()

    print(f"Layout: {len(layout)} groups over {len(directories)} directories "
          f"in {EG_ROOT}/\n")

    # 1 + 2 --------------------------------------------------------------
    assigned = check_coverage(layout, directories, findings)
    classified = classify(layout, targets)

    print("== 1. classification ==\n")
    total_merge = total_move = 0
    for group in sorted(layout):
        buckets = classified[group]
        merge, move, empty = buckets["merge"], buckets["move"], buckets["empty"]
        total_merge += len(merge)
        total_move += len(move)
        print(f"{group}: {len(merge)} module(s) merge, {len(move)} target(s) move as-is")
        if verbose:
            for target in sorted(merge, key=lambda t: t.label):
                print(f"    merge  {target.label}  ({len(target.srcs)} file(s))")
            for target in sorted(move, key=lambda t: t.label):
                print(f"    move   {target.rule:<20} {target.label}")
        for member in empty:
            if member in SPECIAL_CASES:
                advisories.append(
                    f"'{EG_ROOT}/{member}' (group '{group}'): {SPECIAL_CASES[member]}"
                )
            else:
                advisories.append(
                    f"'{EG_ROOT}/{member}' declares no target the scanner "
                    f"recognises (group '{group}') — check it by hand"
                )
    packages = defaultdict(list)
    for group in layout:
        packages[package_of(group)].append(group)
    print(f"\n{total_merge} swift_library targets fold into {len(layout)} modules; "
          f"{total_move} non-Swift targets move but keep their rule.")
    print(f"\nPackage tree — {len(packages)} directories under "
          f"{EG_ROOT}/messenger/:\n")
    for package in sorted(packages):
        modules = sorted(packages[package])
        directories = sorted(d for m in modules for d in layout[m])
        note = f"  [modules: {', '.join(modules)}]" if len(modules) > 1 else ""
        print(f"    {EG_ROOT}/messenger/{package}/{note}")
        print(f"        {len(directories)} directory(ies): "
              f"{', '.join(directories)}")
    print()

    # 2 ------------------------------------------------------------------
    print("== 2. coverage ==\n")
    unassigned = [d for d in directories if d not in assigned and d not in EXCLUDED]
    print(f"    {len(assigned)} directory(ies) assigned, "
          f"{len(EXCLUDED)} excluded ({', '.join(sorted(EXCLUDED))}), "
          f"{len(unassigned)} unaccounted for\n")

    # 3 ------------------------------------------------------------------
    print("== 3. module names ==\n")
    before_names = len(findings)
    check_module_names(layout, targets, findings)
    clashes = len(findings) - before_names
    if clashes:
        print(f"    FAIL: {clashes} new module name(s) collide with a module "
              f"already in the tree\n")
    else:
        print(f"    OK: none of the {len(layout)} new module names collide with "
              f"a module already in the tree\n")

    # 4 ------------------------------------------------------------------
    print("== 4. cycles after contraction ==\n")
    group_of_label = {}
    for group, buckets in classified.items():
        for target in buckets["merge"]:
            group_of_label[target.label] = group

    members_of_group = defaultdict(list)
    for label, group in group_of_label.items():
        members_of_group[group].append(label)

    contracted, provenance = contract(deps_of_label, group_of_label)
    pre_cycle = cbd.find_cycle(deps_of_label)
    if pre_cycle:
        findings.append(
            "the graph already has a cycle before any merge: "
            + " -> ".join(pre_cycle)
        )
        print("the tree already contains a cycle; fix that first\n")

    closure = transitive_closure(deps_of_label)
    bad = [c for c in strongly_connected(contracted) if len(c) > 1]
    if bad:
        involved = sorted({n for c in bad for n in c if n in layout})
        findings.append(
            f"contracting the layout creates {len(bad)} dependency cycle(s), "
            f"involving group(s): {', '.join(involved)}"
        )
        print(f"FAIL: {len(bad)} cycle(s) in the contracted graph.\n")
        for component in sorted(bad, key=len):
            for line in diagnose_component(
                component, layout, members_of_group, closure, provenance
            ):
                print(line)
            print()
        if "--suggest" in argv:
            print("-- suggested split --\n")
            parts, rounds = refine_layout(layout, classified, deps_of_label, closure)
            if rounds < 0:
                print("    could not find an acyclic split automatically\n")
            else:
                before = len(parts)
                parts = coarsen(parts, deps_of_label)
                print(f"    {rounds} split round(s), then coarsened "
                      f"{before} -> {len(parts)} part(s)\n")
                named = name_parts(parts, closure)
                directory_of = {
                    target.label: target.directory
                    for target in targets.values() if target.directory
                }
                suggestion = {}
                for name, labels in named.items():
                    suggestion[name] = sorted(
                        {directory_of[label] for label in labels}
                    )
                # Non-Swift members do not affect cycles; keep them with the
                # feature layer of their original group.
                for group in sorted(layout):
                    leftovers = sorted(
                        {t.directory for t in classified[group]["move"]}
                        | set(classified[group]["empty"])
                    )
                    home = group if group in suggestion else next(
                        (n for n in suggestion if n.startswith(group)), group
                    )
                    for directory in leftovers:
                        if not any(directory in v for v in suggestion.values()):
                            suggestion.setdefault(home, []).append(directory)
                            suggestion[home].sort()
                print(f"    {len(suggestion)} module(s) instead of "
                      f"{len(layout)}\n")
                print(json.dumps(suggestion, indent=4, sort_keys=True))
                print()
    else:
        print(f"OK: no cycle in the contracted graph "
              f"({len(contracted)} nodes, "
              f"{sum(len(v) for v in contracted.values())} edges).\n")

    # 5 ------------------------------------------------------------------
    print("== 5. redeclarations inside a merged module ==\n")
    before = len(findings)
    check_redeclarations(classified, findings, advisories)
    new = len(findings) - before
    if new:
        print(f"    FAIL: {new} name(s) declared in more than one member of a "
              f"group\n")
    else:
        print("    OK: no name is declared in more than one member of a group\n")

    # 6 ------------------------------------------------------------------
    print("== 6. import rewrites ==\n")
    import_report, external = check_imports(classified, targets, layout)
    for group in sorted(layout):
        entry = import_report[group]
        outside = len(external.get(group, ()))
        if not (entry["redundant"] or entry["duplicated"] or outside):
            continue
        print(f"{group}: {entry['redundant']} intra-group import(s) in "
              f"{entry['files']} file(s) become redundant; "
              f"{outside} outside file(s) need the new module name")
        for path, modules in sorted(entry["duplicated"])[: (None if verbose else 3)]:
            print(f"    collapse {' + '.join(modules)} -> import {group}  in {path}")
        if not verbose and len(entry["duplicated"]) > 3:
            print(f"    ... and {len(entry['duplicated']) - 3} more file(s)")
    print()

    # 7 ------------------------------------------------------------------
    print("== 7. leaf-first application order ==\n")
    order, stuck = leaf_first_order(classified, contracted, layout)
    for index, group in enumerate(order, 1):
        needs = sorted(g for g in contracted.get(group, ()) if g in layout)
        suffix = f"  (after {', '.join(needs)})" if needs else "  (no group deps)"
        print(f"    {index:2}. {group}{suffix}")
    if stuck:
        print(f"\n    unorderable, part of a cycle: {', '.join(stuck)}")
    print()

    # 8 ------------------------------------------------------------------
    print("== 8. alias census ==\n")
    counts, files = alias_census()
    referencing = set()
    for label_files in files.values():
        referencing |= label_files
    print(f"    {sum(counts.values())} reference(s) to //{EG_ROOT}/... from "
          f"{len(referencing)} BUILD file(s) outside {EG_ROOT}/")
    print(f"    {len(counts)} distinct label(s) need an alias() left behind")
    if verbose:
        for label in sorted(counts, key=lambda l: (-counts[l], l)):
            print(f"        {counts[label]:3}  {label}")
    unreferenced = [
        target.label
        for target in targets.values()
        if target.directory
        and target.directory in assigned
        and target.label not in counts
    ]
    if unreferenced:
        print(f"    {len(unreferenced)} label(s) have no external reference and "
              f"need no alias")
        if verbose:
            for label in sorted(unreferenced):
                print(f"        {label}")
    print()

    # --------------------------------------------------------------------
    if advisories:
        print("== advisory ==\n")
        for note in advisories:
            print(f"    {note}")
        print()

    if findings:
        print(f"FAIL: {len(findings)} blocking finding(s):\n")
        for note in findings:
            print(f"    {note}")
        print("\nFix the grouping in LAYOUT before touching the tree.")
        return 1

    print("OK: the layout is applicable. Apply the groups in the order above, "
          "one commit per group.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
