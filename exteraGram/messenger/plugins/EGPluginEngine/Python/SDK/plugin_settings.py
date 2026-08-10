"""Plugin settings builder UI."""

from typing import Any, Callable, Optional
import _ios_bridge


class SettingItem:
    def __init__(self, key: str, title: str, subtitle: str = "", default_value: Any = None):
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.default_value = default_value


class SwitchSetting(SettingItem):
    def __init__(self, key: str, title: str, subtitle: str = "", default_value: bool = False, on_change: Optional[Callable] = None):
        super().__init__(key, title, subtitle, default_value)
        self.on_change = on_change


class InputSetting(SettingItem):
    def __init__(self, key: str, title: str, subtitle: str = "", default_value: str = "", placeholder: str = "", on_change: Optional[Callable] = None):
        super().__init__(key, title, subtitle, default_value)
        self.placeholder = placeholder
        self.on_change = on_change


class ListSetting(SettingItem):
    def __init__(self, key: str, title: str, options: list[str], subtitle: str = "", default_value: str = "", on_change: Optional[Callable] = None):
        super().__init__(key, title, subtitle, default_value)
        self.options = options
        self.on_change = on_change


class PluginSettings:
    def __init__(self, plugin_id: str, title: str = "Settings"):
        self.plugin_id = plugin_id
        self.title = title
        self.items: list[SettingItem] = []

    def add_switch(self, key: str, title: str, subtitle: str = "", default_value: bool = False, on_change=None):
        self.items.append(SwitchSetting(key, title, subtitle, default_value, on_change))
        return self

    def add_input(self, key: str, title: str, subtitle: str = "", default_value: str = "", placeholder: str = "", on_change=None):
        self.items.append(InputSetting(key, title, subtitle, default_value, placeholder, on_change))
        return self

    def add_list(self, key: str, title: str, options: list[str], subtitle: str = "", default_value: str = "", on_change=None):
        self.items.append(ListSetting(key, title, options, subtitle, default_value, on_change))
        return self
