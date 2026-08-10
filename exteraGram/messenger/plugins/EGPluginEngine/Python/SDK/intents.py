"""System intents and external actions."""

import _ios_bridge


def open_url(url: str) -> None:
    """Open a URL in default browser."""
    try:
        _ios_bridge.open_url(str(url))
    except Exception:
        pass


def share_text(text: str) -> None:
    """Open system share sheet with text."""
    try:
        _ios_bridge.share_text(str(text))
    except Exception:
        pass
