"""
iOS-specific utilities. No Android equivalent — iOS-only plugins can use these directly.
"""

import _ios_bridge


def run_on_main_thread(func) -> None:
    """Schedule func on the iOS main thread."""
    _ios_bridge.run_on_main_thread(func)


def show_alert(title: str, message: str, button: str = "OK") -> None:
    """Show a UIAlertController with a single dismiss button."""
    try:
        _ios_bridge.show_alert(title, message, button)
    except AttributeError:
        pass


def show_action_sheet(title: str, message: str, options, callback) -> None:
    """
    Show a multi-button alert.  options is a list of button labels;
    when the user taps one, callback(index, label) is invoked.
    """
    try:
        _ios_bridge.show_action_sheet(title, message, list(options), callback)
    except AttributeError:
        pass


def show_toast(message: str, duration: float = 2.0) -> None:
    """Show a brief toast notification (bulletin-style)."""
    try:
        _ios_bridge.show_toast(message, duration)
    except AttributeError:
        pass


def open_url(url: str) -> None:
    """Open a URL in Safari or the in-app browser."""
    try:
        _ios_bridge.open_url(url)
    except AttributeError:
        pass


def copy_to_clipboard(text: str) -> None:
    """Copy text to the iOS pasteboard."""
    try:
        _ios_bridge.copy_to_clipboard(text)
    except AttributeError:
        pass


def read_clipboard() -> str:
    """Return the current pasteboard string contents (empty string if none)."""
    try:
        return _ios_bridge.read_clipboard() or ""
    except AttributeError:
        return ""


def get_screen_info() -> dict:
    """Return main screen geometry: {'width': float, 'height': float, 'scale': float}."""
    try:
        return _ios_bridge.get_screen_info()
    except AttributeError:
        return {"width": 0.0, "height": 0.0, "scale": 1.0}


def haptic_feedback(style: str = "medium") -> None:
    """
    Trigger haptic feedback.
    style: "light" | "medium" | "heavy" | "success" | "warning" | "error"
    """
    try:
        _ios_bridge.haptic_feedback(style)
    except AttributeError:
        pass


def suppress_entity_type(type_name: str, suppress: bool = True) -> None:
    """
    Add or remove a MessageTextEntity type name from TelegramCore's suppressed set.
    When suppressed, entities of that type are dropped before messages are stored.
    Example: suppress_entity_type("Spoiler") strips text-spoiler formatting.
    """
    try:
        _ios_bridge.suppress("entity", type_name, suppress)
    except AttributeError:
        pass


def suppress_attribute_type(type_name: str, suppress: bool = True) -> None:
    """
    Add or remove a MessageAttribute class name from TelegramCore's suppressed set.
    When suppressed, attributes of that class are dropped before messages are stored.
    Example: suppress_attribute_type("MediaSpoilerMessageAttribute") auto-reveals media.
    """
    try:
        _ios_bridge.suppress("attribute", type_name, suppress)
    except AttributeError:
        pass
