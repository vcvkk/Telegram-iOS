"""
Android-compatible utility functions for exteraGram iOS plugins.

All function names and signatures match the Android SDK so plugins can run
without modification. iOS-specific behaviour is provided via _ios_bridge.
"""

import _ios_bridge

# ---------------------------------------------------------------------------
# Logging (Android: log(data) → Logcat; iOS: log(data) → EGLogger)
# ---------------------------------------------------------------------------

def log(data) -> None:
    """Log data to EGLogger. Scalar types log as text; objects log as repr."""
    if isinstance(data, (str, int, float, bool, type(None))):
        _ios_bridge.log("Android", str(data))
    else:
        _ios_bridge.log("Android", f"<{type(data).__module__}.{type(data).__name__}>: {repr(data)}")


# ---------------------------------------------------------------------------
# String / locale (Android: getString(key); iOS: EGLocalizationManager)
# ---------------------------------------------------------------------------

def get_string(key: str, default: str = "") -> str:
    """Return a localised string by key, or default if not found."""
    try:
        return _ios_bridge.get_string(key) or default
    except AttributeError:
        return default


def get_locale_language() -> str:
    """Return the current UI language code (e.g. 'en', 'ru')."""
    try:
        return _ios_bridge.get_locale_language()
    except AttributeError:
        return "en"


# ---------------------------------------------------------------------------
# Threading (Android: AndroidUtilities.runOnUIThread; iOS: main queue)
# ---------------------------------------------------------------------------

def run_on_ui_thread(func) -> None:
    """Schedule func to run on the main thread."""
    _ios_bridge.run_on_main_thread(func)


# ---------------------------------------------------------------------------
# Plugin settings (Android: SharedPreferences; iOS: UserDefaults)
# ---------------------------------------------------------------------------

def get_plugin_setting(plugin_id: str, key: str, default=None):
    """Read a persisted setting for the given plugin."""
    try:
        return _ios_bridge.get_plugin_setting(plugin_id, key, default)
    except AttributeError:
        return default


def set_plugin_setting(plugin_id: str, key: str, value) -> None:
    """Persist a setting for the given plugin."""
    try:
        _ios_bridge.set_plugin_setting(plugin_id, key, value)
    except AttributeError:
        pass


# ---------------------------------------------------------------------------
# Android stubs — no-ops on iOS (keep for source compatibility)
# ---------------------------------------------------------------------------

def dynamic_proxy(interface_name: str, handler):
    """
    Android: creates a Java dynamic proxy.
    iOS: returns the handler directly (Python callables work natively).
    """
    return handler


class ApplicationLoader:
    """Stub for Android ApplicationLoader. On iOS, use ios_utils instead."""
    applicationContext = None


class NotificationCenter:
    """Stub for Android NotificationCenter. Use Swift notification system instead."""

    @staticmethod
    def getInstance(account: int = 0):
        return _NotificationCenterStub()


class _NotificationCenterStub:
    def addObserver(self, *args, **kwargs): pass
    def removeObserver(self, *args, **kwargs): pass
    def postNotificationName(self, *args, **kwargs): pass
