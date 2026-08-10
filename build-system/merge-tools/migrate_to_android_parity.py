#!/usr/bin/env python3
"""Execute the Android-parity module migration for exteraGram."""

import os
import re
import shutil
import json
from collections import defaultdict

import check_build_deps as cbd
import plan_module_merge as pmm

REPO_ROOT = cbd.REPO_ROOT
EG_ROOT = "exteraGram"
EG_DIR = os.path.join(REPO_ROOT, EG_ROOT)
MESSENGER_DIR = os.path.join(EG_DIR, "messenger")


def clean_import_block(content, remove_modules, rename_map):
    """Remove redundant intra-group imports and rename modules."""
    lines = content.splitlines(keepends=True)
    out_lines = []
    seen_imports = set()

    for line in lines:
        match = re.match(r"^(\s*import\s+)([A-Za-z0-9_]+)(.*)$", line)
        if match:
            prefix, mod, suffix = match.groups()
            if mod in remove_modules:
                continue
            if mod in rename_map:
                mod = rename_map[mod]
            new_line = f"{prefix}{mod}{suffix}"
            import_sig = f"{mod}{suffix.strip()}"
            if import_sig in seen_imports:
                continue
            seen_imports.add(import_sig)
            out_lines.append(new_line)
        else:
            out_lines.append(line)

    return "".join(out_lines)


def run_migration():
    print("Starting Android-parity migration...")
    targets, filegroup_files = pmm.inventory()
    classified = pmm.classify(pmm.LAYOUT, targets)

    path_map = {}
    alias_map = {}  # old_label -> new_label
    module_rename_map = {}  # old_module_name -> new_module_name
    for group, buckets in classified.items():
        for target in buckets["merge"]:
            if target.module_name:
                module_rename_map[target.module_name] = group

    # Create messenger root
    os.makedirs(MESSENGER_DIR, exist_ok=True)

    packages = defaultdict(lambda: {"modules": defaultdict(list), "moves": []})

    for group, buckets in classified.items():
        pkg = pmm.package_of(group)
        packages[pkg]["modules"][group].extend(buckets["merge"])
        packages[pkg]["moves"].extend(buckets["move"])

    # 1. Process each package
    for pkg, pdata in sorted(packages.items()):
        pkg_dir = os.path.join(MESSENGER_DIR, pkg)
        os.makedirs(pkg_dir, exist_ok=True)
        print(f"\nProcessing package '{pkg}' in {pkg_dir}...")

        build_rules = []
        needs_swift = bool(pdata["modules"])
        needs_objc = False
        needs_apple_bundle = False

        for mod_name, merge_targets in sorted(pdata["modules"].items()):
            print(f"  Building merged module '{mod_name}' ({len(merge_targets)} targets)...")
            
            mod_src_dir = os.path.join(pkg_dir, mod_name)
            os.makedirs(mod_src_dir, exist_ok=True)

            intra_modules = {t.module_name for t in merge_targets if t.module_name}
            all_deps = set()

            for target in merge_targets:
                old_dir = os.path.join(EG_DIR, target.directory)
                target_dest_dir = os.path.join(mod_src_dir, target.directory)
                
                # Copy all Swift sources
                for src_path in target.srcs:
                    if not src_path.endswith(".swift"):
                        continue
                    rel_to_old = os.path.relpath(src_path, old_dir)
                    dest_path = os.path.join(target_dest_dir, rel_to_old)
                    os.makedirs(os.path.dirname(dest_path), exist_ok=True)

                    content = pmm.read(src_path)
                    cleaned_content = clean_import_block(
                        content,
                        remove_modules=intra_modules,
                        rename_map=module_rename_map,
                    )
                    with open(dest_path, "w") as f:
                        f.write(cleaned_content)

                    # Track path mapping
                    rel_old = os.path.relpath(src_path, REPO_ROOT)
                    rel_new = os.path.relpath(dest_path, REPO_ROOT)
                    path_map[rel_old] = rel_new

                # Collect dependencies
                old_build_path = os.path.join(old_dir, "BUILD")
                if os.path.exists(old_build_path):
                    body = pmm.read(old_build_path)
                    deps_match = re.search(r"deps\s*=\s*\[(.*?)\]", body, re.S)
                    if deps_match:
                        for d in re.findall(r'"([^"]+)"', deps_match.group(1)):
                            all_deps.add(d)

                alias_map[target.label] = f"//exteraGram/messenger/{pkg}:{mod_name}"

            # Filter deps: remove intra-group deps, map remaining
            clean_deps = set()
            for d in sorted(all_deps):
                can_d = cbd.canonical(d)
                if any(t.label == can_d for t in merge_targets):
                    continue
                clean_deps.add(d)

            src_glob = f"{mod_name}/**/*.swift"
            deps_str = "\n".join(f'        "{d}",' for d in sorted(clean_deps))
            build_rules.append(f"""swift_library(
    name = "{mod_name}",
    module_name = "{mod_name}",
    srcs = glob([
        "{src_glob}",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
{deps_str}
    ],
    visibility = [
        "//visibility:public",
    ],
)""")

        # Process move targets
        for target in pdata["moves"]:
            print(f"  Moving target '{target.name}' ({target.rule}) from '{target.directory}'...")
            old_dir = os.path.join(EG_DIR, target.directory)
            dest_target_dir = os.path.join(pkg_dir, target.directory)
            
            if os.path.exists(old_dir):
                for item in os.listdir(old_dir):
                    if item == "BUILD":
                        continue
                    s_path = os.path.join(old_dir, item)
                    d_path = os.path.join(dest_target_dir, item)
                    if os.path.isdir(s_path):
                        if os.path.exists(d_path):
                            shutil.rmtree(d_path)
                        shutil.copytree(s_path, d_path)
                    else:
                        os.makedirs(os.path.dirname(d_path), exist_ok=True)
                        shutil.copy2(s_path, d_path)

            for root, _, files in os.walk(dest_target_dir):
                for file in files:
                    full_new = os.path.join(root, file)
                    rel_to_target = os.path.relpath(full_new, dest_target_dir)
                    full_old = os.path.join(old_dir, rel_to_target)
                    if os.path.exists(full_old):
                        path_map[os.path.relpath(full_old, REPO_ROOT)] = os.path.relpath(full_new, REPO_ROOT)

            old_build = pmm.read(os.path.join(old_dir, "BUILD"))
            for m in pmm.RULE_RE.finditer(old_build):
                r_type = m.group("rule")
                r_body = m.group("body")
                if re.search(rf'name\s*=\s*"{re.escape(target.name)}"', r_body):
                    if r_type == "objc_library":
                        needs_objc = True
                    elif r_type == "apple_bundle_import":
                        needs_apple_bundle = True
                    
                    def repl_path(pm):
                        p = pm.group(1)
                        if p.startswith(("//", ":", "@")):
                            return pm.group(0)
                        return f'"{target.directory}/{p}"'

                    new_body = re.sub(r'"([^"]+)"', repl_path, r_body)
                    build_rules.append(f"{r_type}(\n    {new_body.strip()}\n)")

            alias_map[target.label] = f"//exteraGram/messenger/{pkg}:{target.name}"

        # Check for special case FLEX in debug
        if pkg == "debug" and os.path.exists(os.path.join(EG_DIR, "FLEX")):
            print("  Copying FLEX to debug package...")
            dest_flex = os.path.join(pkg_dir, "FLEX")
            os.makedirs(dest_flex, exist_ok=True)
            for item in os.listdir(os.path.join(EG_DIR, "FLEX")):
                s = os.path.join(EG_DIR, "FLEX", item)
                d = os.path.join(dest_flex, item)
                if not os.path.exists(d):
                    if os.path.isdir(s):
                        shutil.copytree(s, d)
                    else:
                        shutil.copy2(s, d)
            alias_map["//exteraGram/FLEX:FLEX"] = "//exteraGram/messenger/debug/FLEX:FLEX"

        # Write package BUILD file
        pkg_build_path = os.path.join(pkg_dir, "BUILD")
        headers = []
        if needs_swift:
            headers.append('load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")')
        if needs_objc:
            headers.append('load("@build_bazel_rules_apple//apple:objc_library.bzl", "objc_library")')
        if needs_apple_bundle:
            headers.append('load("@build_bazel_rules_apple//apple:resources.bzl", "apple_bundle_import")')

        with open(pkg_build_path, "w") as f:
            if headers:
                f.write("\n".join(headers) + "\n\n")
            f.write("\n\n".join(build_rules) + "\n")

    # 2. Write aliases in old directories
    print("\nSetting up alias() in legacy exteraGram directories...")
    excluded_dirs = pmm.EXCLUDED | {"messenger"}
    for old_dir_name in pmm.eg_directories():
        if old_dir_name in excluded_dirs:
            continue
        old_dir = os.path.join(EG_DIR, old_dir_name)
        old_build = os.path.join(old_dir, "BUILD")
        
        aliases = []
        if os.path.exists(old_build):
            content = pmm.read(old_build)
            for m in pmm.RULE_RE.finditer(content):
                r_body = m.group("body")
                n_match = re.search(r'name\s*=\s*"([^"]+)"', r_body)
                if n_match:
                    t_name = n_match.group(1)
                    old_label = f"//exteraGram/{old_dir_name}:{t_name}"
                    new_label = alias_map.get(old_label, alias_map.get(f"//exteraGram/{old_dir_name}:{old_dir_name}"))
                    if new_label:
                        aliases.append(f"""alias(
    name = "{t_name}",
    actual = "{new_label}",
    visibility = ["//visibility:public"],
)""")

        if not aliases:
            old_label = f"//exteraGram/{old_dir_name}:{old_dir_name}"
            if old_label in alias_map:
                aliases.append(f"""alias(
    name = "{old_dir_name}",
    actual = "{alias_map[old_label]}",
    visibility = ["//visibility:public"],
)""")

        # Clean old sources from old_dir, keep only BUILD
        for item in list(os.listdir(old_dir)):
            item_path = os.path.join(old_dir, item)
            if item in ("BUILD", "FLEX.BUILD"):
                continue
            if os.path.isdir(item_path):
                shutil.rmtree(item_path)
            else:
                os.remove(item_path)

        with open(old_build, "w") as f:
            f.write("\n\n".join(aliases) + "\n")

    # 3. Update MODULE.bazel for FLEX
    module_bazel_path = os.path.join(REPO_ROOT, "MODULE.bazel")
    if os.path.exists(module_bazel_path):
        m_content = pmm.read(module_bazel_path)
        m_content = m_content.replace(
            '"@//exteraGram/FLEX:FLEX.BUILD"',
            '"@//exteraGram/messenger/debug/FLEX:FLEX.BUILD"'
        )
        with open(module_bazel_path, "w") as f:
            f.write(m_content)
        print("Updated MODULE.bazel FLEX reference.")

    # 4. Save path_map.json
    path_map_file = os.path.join(REPO_ROOT, "build-system", "merge-tools", "path_map.json")
    with open(path_map_file, "w") as f:
        json.dump(path_map, f, indent=2, sort_keys=True)
    print(f"Generated {path_map_file} with {len(path_map)} path mappings.")

    print("\nMigration completed successfully!")


if __name__ == "__main__":
    run_migration()
