"""Public API for structured Elyx plugins."""

from __future__ import annotations
import java
from typing import Any

View = java.jclass("android.view.View")
JavaRunnable = java.jclass("java.lang.Runnable")
Utilities = java.jclass("org.telegram.messenger.Utilities")

from elyxcore.assets import (
    Asset,
    AssetNotFoundException,
    Assets,
    AssetsDirNotFoundException,
)
from elyxcore.localization import Strings
from elyxcore.settings import SettingsController
from elyxcore.utils import LazyDict, gen, gen2, mvel_execute

OnClickListener = gen(View, "onClick")
Runnable = gen(JavaRunnable, "run")
Callback = gen(Utilities, "run")
Callback2 = gen(Utilities, "run")
Callback3 = gen(Utilities, "run")
CallbackReturn = gen(Utilities, "run", True)


def get_environment() -> dict[str, Any]:
    """Return assets, settings, strings and metadata for the calling plugin."""
    from elyxcore._importer import importer
    plugin = importer.get_caller_plugin()
    if plugin is None:
        raise RuntimeError("No active plugin environment found for caller.")
    return plugin.get_environment_vars()


def import_module(name: str, package: str | None = None):
    """Import a module relative to the calling plugin when it exists locally."""
    from elyxcore._importer import importer
    return importer.import_module(name, package)


__all__ = (
    "Asset",
    "AssetNotFoundException",
    "Assets",
    "AssetsDirNotFoundException",
    "Callback",
    "Callback2",
    "Callback3",
    "CallbackReturn",
    "LazyDict",
    "OnClickListener",
    "Runnable",
    "SettingsController",
    "Strings",
    "gen",
    "gen2",
    "get_environment",
    "import_module",
    "mvel_execute",
)
