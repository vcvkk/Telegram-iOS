"""
EGPluginEngine package manager — runtime installer for pure-Python packages.

C-extension packages (Pillow, aiohttp, numpy, etc.) are pre-bundled in
BeewarePackages.framework and available without network access.
This module handles pure-Python packages only: downloads from PyPI,
extracts the wheel to site-packages, and remembers installed versions.

Usage (called from ObjC installRequirements:forPlugin:):
    import pkg_manager
    ok = pkg_manager.ensure_requirements(["requests>=2.28", "pyyaml"])
"""

import sys
import os
import json
import zipfile
import urllib.request
import importlib.util
import re

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

def _site_packages() -> str:
    for p in sys.path:
        if "site-packages" in p:
            return p
    # Fallback: look for Documents/EGPlugins/site-packages
    for p in sys.path:
        if "EGPlugins" in p:
            return p
    return sys.path[-1]

_SITE_PKGS = _site_packages()
_REGISTRY_PATH = os.path.join(_SITE_PKGS, ".pkg_registry.json")

# ---------------------------------------------------------------------------
# Pre-bundled packages (available via BeewarePackages.framework — no download needed)
# ---------------------------------------------------------------------------

_PREBUNDLED = {
    "pillow": "11.0.0",
    "pil": "11.0.0",       # alias
    "aiohttp": "3.10.5",
    "numpy": "2.3.5",
    "cffi": "2.0.0",
    "cryptography": "47.0.0",
    "yarl": "1.9.7",
    "brotli": "1.1.0",
    "bcrypt": "3.1.7",
    "kiwisolver": "1.3.2",
    "contourpy": "1.0.5",
    "aiosignal": "1.4.0",
    "async-timeout": "5.0.1",
    "async_timeout": "5.0.1",
    "attrs": "24.3.0",
    "attr": "24.3.0",
    "multidict": "6.1.0",
    "frozenlist": "1.5.0",
    "pycparser": "2.22",
    # rubicon-objc: pure-Python ObjC bridge (BeeWare). Always available — no
    # requirements line needed. `import rubicon.objc` works out of the box.
    "rubicon-objc": "0.5.4",
    "rubicon_objc": "0.5.4",  # pip normalised form
    "rubicon": "0.5.4",       # top-level import alias
}

# ---------------------------------------------------------------------------
# Registry: tracks installed pure-Python packages
# ---------------------------------------------------------------------------

def _load_registry() -> dict:
    try:
        with open(_REGISTRY_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def _save_registry(reg: dict) -> None:
    os.makedirs(_SITE_PKGS, exist_ok=True)
    try:
        with open(_REGISTRY_PATH, "w", encoding="utf-8") as f:
            json.dump(reg, f)
    except Exception:
        pass

# ---------------------------------------------------------------------------
# Version parsing & comparison
# ---------------------------------------------------------------------------

def _parse_version(v: str) -> tuple:
    """Convert version string to comparable tuple of ints."""
    v = v.strip().split("+")[0].split(".post")[0].split("a")[0].split("b")[0].split("rc")[0]
    try:
        return tuple(int(x) for x in v.split("."))
    except ValueError:
        return (0,)

def parse_req(s: str) -> tuple:
    """Parse PEP 508 requirement string into (name, [(op, version), ...])."""
    s = s.strip()
    m = re.match(r'^([A-Za-z0-9_\-\.]+)\s*(.*)', s)
    if not m:
        return (s, [])
    name = m.group(1).lower().replace("-", "_")
    spec_str = m.group(2).strip()
    specs = []
    for part in re.findall(r'(~=|==|!=|<=|>=|<|>)\s*([^\s,;]+)', spec_str):
        specs.append((part[0], part[1]))
    return (name, specs)

def _satisfies(installed_ver: str, op: str, required_ver: str) -> bool:
    iv = _parse_version(installed_ver)
    rv = _parse_version(required_ver)
    if op == "==":   return iv == rv
    if op == "!=":   return iv != rv
    if op == ">=":   return iv >= rv
    if op == "<=":   return iv <= rv
    if op == ">":    return iv > rv
    if op == "<":    return iv < rv
    if op == "~=":
        # Compatible release: >=required and major.minor match
        return iv >= rv and iv[:len(rv)-1] == rv[:len(rv)-1]
    return True

def _version_satisfies_specs(version: str, specs: list) -> bool:
    return all(_satisfies(version, op, v) for op, v in specs)

# ---------------------------------------------------------------------------
# Check if package is satisfied
# ---------------------------------------------------------------------------

def is_satisfied(name: str, specs: list) -> bool:
    key = name.lower().replace("-", "_")

    # 1. Check pre-bundled packages
    if key in _PREBUNDLED:
        ver = _PREBUNDLED[key]
        return not specs or _version_satisfies_specs(ver, specs)

    # 2. Check if importable (already in sys.path / installed previously)
    spec = importlib.util.find_spec(key)
    if spec is not None:
        # Try to find version
        reg = _load_registry()
        if key in reg:
            return not specs or _version_satisfies_specs(reg[key], specs)
        return True  # importable but version unknown — accept

    # 3. Check registry
    reg = _load_registry()
    if key in reg:
        return not specs or _version_satisfies_specs(reg[key], specs)

    return False

# ---------------------------------------------------------------------------
# PyPI interaction
# ---------------------------------------------------------------------------

def _fetch_pypi_meta(name: str) -> dict:
    url = "https://pypi.org/pypi/{}/json".format(name)
    req = urllib.request.Request(url, headers={"User-Agent": "exteraGram/1.0 pkg_manager"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode("utf-8"))

def _pick_wheel(releases: dict, version: str) -> str | None:
    """Pick the best pure-Python wheel for a given version."""
    files = releases.get(version, [])
    for f in files:
        fn = f.get("filename", "")
        # Accept only pure-Python wheels (py3-none-any or py2.py3-none-any)
        if not fn.endswith(".whl"):
            continue
        parts = fn.rsplit("-", 4)
        if len(parts) < 5:
            continue
        # parts: name-ver-py-abi-plat.whl
        py_tag, abi_tag, plat_tag = parts[2], parts[3], parts[4].replace(".whl", "")
        if plat_tag != "any":
            continue  # C extension wheel — skip
        if "none" not in abi_tag:
            continue
        return f["url"]
    return None

def _extract_wheel(url: str, dest_dir: str) -> bool:
    req = urllib.request.Request(url, headers={"User-Agent": "exteraGram/1.0 pkg_manager"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read()
    except Exception as e:
        print("[pkg_manager] download failed:", e)
        return False
    os.makedirs(dest_dir, exist_ok=True)
    import io
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            for member in zf.namelist():
                if member.endswith(".dist-info/RECORD"):
                    continue
                if "/__pycache__/" in member or member.endswith(".pyc"):
                    continue
                zf.extract(member, dest_dir)
    except Exception as e:
        print("[pkg_manager] extract failed:", e)
        return False
    return True

# ---------------------------------------------------------------------------
# Install a package from PyPI (pure-Python only)
# ---------------------------------------------------------------------------

def install_package(name: str, specs: list) -> bool:
    key = name.lower().replace("-", "_")
    try:
        meta = _fetch_pypi_meta(name)
    except Exception as e:
        print("[pkg_manager] PyPI fetch failed for {}: {}".format(name, e))
        return False

    # Determine which version to install
    all_versions = list(meta.get("releases", {}).keys())
    # Filter to versions that satisfy specs, pick latest compatible
    compatible = []
    for v in all_versions:
        if not specs or _version_satisfies_specs(v, specs):
            compatible.append(v)
    if not compatible:
        print("[pkg_manager] no compatible version for", name, specs)
        return False

    compatible.sort(key=_parse_version, reverse=True)
    chosen_ver = compatible[0]

    wheel_url = _pick_wheel(meta["releases"], chosen_ver)
    if not wheel_url:
        print("[pkg_manager] no pure-Python wheel for {} {}".format(name, chosen_ver))
        return False

    print("[pkg_manager] installing {} {}...".format(name, chosen_ver))
    ok = _extract_wheel(wheel_url, _SITE_PKGS)
    if ok:
        reg = _load_registry()
        reg[key] = chosen_ver
        _save_registry(reg)
        # Ensure site-packages is on sys.path
        if _SITE_PKGS not in sys.path:
            sys.path.append(_SITE_PKGS)
    return ok

# ---------------------------------------------------------------------------
# Main entry point — called from ObjC installRequirements:forPlugin:
# ---------------------------------------------------------------------------

def ensure_requirements(reqs: list) -> bool:
    """Install all requirements. Returns True if all are satisfied after."""
    all_ok = True
    for req_str in reqs:
        if not req_str.strip():
            continue
        name, specs = parse_req(req_str)
        if is_satisfied(name, specs):
            continue
        ok = install_package(name, specs)
        if not ok:
            print("[pkg_manager] failed to install:", req_str)
            all_ok = False
    return all_ok
