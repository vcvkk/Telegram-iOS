"""Settings management for Elyx plugins."""

from typing import Any
import _ios_bridge


class SettingsController:
    """Manages persistent key-value configuration for an Elyx plugin."""

    def __init__(self, plugin_id: str):
        self._plugin_id = plugin_id

    def get(self, key: str, default: Any = None) -> Any:
        try:
            val = _ios_bridge.get_plugin_setting(self._plugin_id, key, default)
            return val if val is not None else default
        except Exception:
            return default

    def set(self, key: str, value: Any) -> None:
        try:
            _ios_bridge.set_plugin_setting(self._plugin_id, key, value)
        except Exception:
            pass

    def __getitem__(self, key: str) -> Any:
        return self.get(key)

    def __setitem__(self, key: str, value: Any) -> None:
        self.set(key, value)
