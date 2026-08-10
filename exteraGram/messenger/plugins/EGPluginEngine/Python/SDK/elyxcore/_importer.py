"""Plugin module importer with environment isolation."""

import sys
import os
import inspect
from typing import Any, Optional


class _PluginContext:
    def __init__(self, plugin_id: str, base_dir: str):
        self.plugin_id = plugin_id
        self.base_dir = base_dir
        self.assets_dir = os.path.join(base_dir, "assets")

    def get_environment_vars(self) -> dict[str, Any]:
        from elyxcore.assets import Assets
        from elyxcore.localization import Strings
        from elyxcore.settings import SettingsController

        strings_path = os.path.join(self.base_dir, "strings.json")
        return {
            "assets": Assets(self.assets_dir),
            "settings": SettingsController(self.plugin_id),
            "strings": Strings.from_file(strings_path),
            "metainfo": {"id": self.plugin_id, "dir": self.base_dir},
            "refmap": {},
        }


class _Importer:
    def __init__(self):
        self._active_plugins: dict[str, _PluginContext] = {}

    def register_plugin(self, plugin_id: str, base_dir: str) -> _PluginContext:
        ctx = _PluginContext(plugin_id, base_dir)
        self._active_plugins[plugin_id] = ctx
        return ctx

    def unregister_plugin(self, plugin_id: str):
        self._active_plugins.pop(plugin_id, None)

    def get_caller_plugin(self) -> Optional[_PluginContext]:
        stack = inspect.stack()
        for frame_info in stack[1:]:
            filename = frame_info.filename
            for ctx in self._active_plugins.values():
                if filename.startswith(ctx.base_dir):
                    return ctx
        # Fallback to last registered plugin if in single execution mode
        if self._active_plugins:
            return next(reversed(self._active_plugins.values()))
        return _PluginContext("default", os.getcwd())

    def import_module(self, name: str, package: str | None = None):
        import importlib
        return importlib.import_module(name, package)


importer = _Importer()
