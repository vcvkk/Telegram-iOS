"""Bulletin / toast notification UI for plugins."""

import _ios_bridge


def show_bulletin(text: str, subtitle: str = "", icon: str = "info.circle") -> None:
    """Show standard bulletin toast."""
    try:
        _ios_bridge.show_bulletin(str(text), str(subtitle), str(icon))
    except Exception:
        pass


def show_success_bulletin(text: str, subtitle: str = "") -> None:
    """Show green success bulletin toast."""
    show_bulletin(text, subtitle, "checkmark.circle.fill")


def show_error_bulletin(text: str, subtitle: str = "") -> None:
    """Show red error bulletin toast."""
    show_bulletin(text, subtitle, "exclamationmark.triangle.fill")
