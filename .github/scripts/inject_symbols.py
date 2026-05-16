#!/usr/bin/env python3
"""
Extracts symbol tables from .dSYM bundles and injects them into an IPA.

For each .dSYM, runs `nm` to get text-section symbols, demangles Swift names,
then stores sorted tab-separated (hex_addr<TAB>name) text files inside the IPA
at Payload/<App>.app/eg_symbols/<FrameworkName>.sym

The IPA's own zip compression handles size; no extra compression is needed.
"""

import os
import re
import sys
import subprocess
import zipfile
import tempfile
import shutil

# Mach-O arm64 main-executable base address; subtract if symbols start here
MACHO_ARM64_BASE = 0x100000000


def nm_symbols(binary: str) -> list[tuple[int, str]]:
    """Return sorted [(addr, raw_name)] for text-section symbols in binary."""
    try:
        out = subprocess.check_output(
            ["nm", "-arch", "arm64", "-U", "-p", binary],
            stderr=subprocess.DEVNULL,
        ).decode(errors="replace")
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []

    pairs: list[tuple[int, str]] = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        addr_str, sym_type, name = parts
        if sym_type not in ("T", "t"):
            continue
        try:
            pairs.append((int(addr_str, 16), name))
        except ValueError:
            continue

    pairs.sort()

    # Normalise: subtract the Mach-O base if symbols look like a main executable
    if pairs and pairs[0][0] >= MACHO_ARM64_BASE:
        pairs = [(a - MACHO_ARM64_BASE, n) for a, n in pairs]

    return pairs


def demangle(names: list[str]) -> list[str]:
    """Demangle a list of Swift/C++ mangled names using swift-demangle."""
    if not names:
        return names
    joined = "\n".join(names)
    try:
        out = subprocess.check_output(
            ["xcrun", "swift-demangle", "--compact"],
            input=joined.encode(),
            stderr=subprocess.DEVNULL,
        ).decode(errors="replace")
        demangled = out.splitlines()
        if len(demangled) == len(names):
            return demangled
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return names


def process_dsym(dsym_path: str) -> str | None:
    """
    Extract and demangle symbols from a .dSYM bundle.
    Returns a multi-line string 'hex_addr\\tname\\n...' or None on failure.
    """
    dwarf_dir = os.path.join(dsym_path, "Contents", "Resources", "DWARF")
    if not os.path.isdir(dwarf_dir):
        return None
    binaries = os.listdir(dwarf_dir)
    if not binaries:
        return None
    binary = os.path.join(dwarf_dir, binaries[0])

    pairs = nm_symbols(binary)
    if not pairs:
        return None

    raw_names = [name for _, name in pairs]
    nice_names = demangle(raw_names)

    lines = [f"{addr:x}\t{name}" for (addr, _), name in zip(pairs, nice_names)]
    return "\n".join(lines)


def app_bundle_prefix(ipa: str) -> str | None:
    """Return e.g. 'Payload/exteraGram.app' from the IPA's zip listing."""
    with zipfile.ZipFile(ipa) as z:
        for name in z.namelist():
            parts = name.split("/")
            if (
                len(parts) >= 2
                and parts[0] == "Payload"
                and parts[1].endswith(".app")
            ):
                return f"Payload/{parts[1]}"
    return None


def inject(ipa: str, sym_files: dict[str, str]) -> None:
    """Add symbol map text files to the IPA zip."""
    prefix = app_bundle_prefix(ipa)
    if not prefix:
        print("ERROR: Cannot find Payload/<App>.app in IPA", file=sys.stderr)
        sys.exit(1)

    with zipfile.ZipFile(ipa, "a", compression=zipfile.ZIP_DEFLATED) as z:
        for framework, content in sym_files.items():
            arc_name = f"{prefix}/eg_symbols/{framework}.sym"
            z.writestr(arc_name, content)
            print(f"  injected: {arc_name} ({len(content):,} bytes)")


def main() -> None:
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <dsyms_dir> <ipa_path>")
        sys.exit(1)

    dsyms_dir = sys.argv[1]
    ipa_path = sys.argv[2]

    if not os.path.isdir(dsyms_dir):
        print(f"ERROR: DSYMs directory not found: {dsyms_dir}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(ipa_path):
        print(f"ERROR: IPA not found: {ipa_path}", file=sys.stderr)
        sys.exit(1)

    sym_files: dict[str, str] = {}

    for entry in sorted(os.listdir(dsyms_dir)):
        if not entry.endswith(".dSYM"):
            continue
        framework = entry.removesuffix(".dSYM")
        dsym_path = os.path.join(dsyms_dir, entry)
        print(f"Processing {framework}...", flush=True)
        content = process_dsym(dsym_path)
        if content:
            symbol_count = content.count("\n") + 1
            print(f"  {symbol_count:,} symbols")
            sym_files[framework] = content
        else:
            print("  (no symbols found)")

    if not sym_files:
        print("No symbol maps generated — skipping injection.")
        return

    print(f"\nInjecting {len(sym_files)} symbol map(s) into {os.path.basename(ipa_path)}...")
    inject(ipa_path, sym_files)
    print("Done.")


if __name__ == "__main__":
    main()
