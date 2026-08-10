"""Settings screen rendering."""

from plugin_settings import PluginSettings, SettingItem, SwitchSetting, InputSetting, ListSetting
import _ios_bridge


def show_settings_screen(settings: PluginSettings) -> None:
    """Open settings screen for the given plugin configuration."""
    try:
        _ios_bridge.show_settings_screen(settings.plugin_id, settings.title)
    except Exception:
        pass
