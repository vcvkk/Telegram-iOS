"""Bulletin (toast-style notification) for iOS plugins."""

import _ios_bridge


def show_bulletin(title: str, text: str = "", icon: str = "") -> None:
    """
    Show a Telegram-style bulletin notification.

    Args:
        title: Bold title text
        text:  Optional subtitle text
        icon:  Optional SF Symbol name (e.g. "checkmark.circle.fill")
    """
    try:
        _ios_bridge.show_bulletin(title, text, icon)
    except AttributeError:
        # Fallback to log if not yet implemented in bridge
        import _ios_bridge as b
        b.log_text(f"[Bulletin] {title}: {text}")
