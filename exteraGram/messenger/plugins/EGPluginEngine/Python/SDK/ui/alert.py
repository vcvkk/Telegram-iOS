"""Alert and dialog UI builder."""

from typing import Callable, Optional
import _ios_bridge
from eg_widgets import AlertDialogBuilder


def show_alert(title: str, message: str, button_text: str = "OK") -> None:
    """Display a simple native alert."""
    try:
        _ios_bridge.show_alert(str(title), str(message), str(button_text))
    except Exception:
        pass


def show_confirm_dialog(title: str, message: str, on_confirm: Callable, on_cancel: Optional[Callable] = None) -> None:
    """Display confirmation dialog with OK and Cancel."""
    try:
        _ios_bridge.show_confirm_dialog(str(title), str(message), on_confirm, on_cancel)
    except Exception:
        pass
