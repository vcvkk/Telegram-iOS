"""Plugin settings UI. Rendered as an iOS list screen via _ios_bridge."""

import _ios_bridge
from dataclasses import dataclass, field
from typing import Any, List, Optional, Callable


@dataclass
class SettingItem:
    """A single setting row."""
    key: str
    title: str
    subtitle: str = ""
    type: str = "toggle"        # "toggle" | "text" | "slider" | "select"
    default: Any = None
    options: List[Any] = field(default_factory=list)   # for "select" type
    on_change: Optional[Callable[[Any], None]] = None


class PluginSettings:
    """
    Declares plugin settings. Pass to the engine from the plugin module-level:

        __settings__ = PluginSettings([
            SettingItem("big", "Always big reactions", type="toggle", default=True),
        ])
    """

    def __init__(self, items: List[SettingItem]):
        self.items = items

    def to_dict(self) -> dict:
        return {
            "items": [
                {
                    "key": item.key,
                    "title": item.title,
                    "subtitle": item.subtitle,
                    "type": item.type,
                    "default": item.default,
                    "options": item.options,
                }
                for item in self.items
            ]
        }


def show_settings_screen(plugin_id: str) -> None:
    """
    Request the host app to show the settings screen for the given plugin.
    The screen is built from the plugin's __settings__ attribute if present.
    """
    try:
        _ios_bridge.show_plugin_settings(plugin_id)
    except AttributeError:
        pass
