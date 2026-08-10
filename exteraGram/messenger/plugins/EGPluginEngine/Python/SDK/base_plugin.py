"""Base class for exteraGram iOS plugins. API-compatible with Android SDK."""


class Plugin:
    """
    Base class all plugins should subclass (or at least implement on_load/on_unload).

    Lifecycle:
        on_load(plugin)   — called once after the module is imported and executed
        on_unload(plugin) — called before the plugin is removed
    """

    def __init__(self):
        # Internal hook registry: {tl_type: [callback, ...]}
        self.__hooks__ = {}
        # Plugin settings storage key prefix
        self.__settings_prefix__ = getattr(self, "__id__", type(self).__name__)

    # ------------------------------------------------------------------
    # Lifecycle — override in subclass
    # ------------------------------------------------------------------

    def on_load(self):
        """Called once when the plugin is loaded. Register hooks here."""
        pass

    def on_unload(self):
        """Called before the plugin is unloaded. Clean up resources."""
        pass

    # ------------------------------------------------------------------
    # Convenience wrappers
    # ------------------------------------------------------------------

    def log(self, *args):
        """Log a message to EGLogger under the plugin's tag."""
        from android_utils import log as _log
        _log(" ".join(str(a) for a in args))

    def get_setting(self, key: str, default=None):
        from android_utils import get_plugin_setting
        return get_plugin_setting(self.__settings_prefix__, key, default)

    def set_setting(self, key: str, value):
        from android_utils import set_plugin_setting
        set_plugin_setting(self.__settings_prefix__, key, value)
