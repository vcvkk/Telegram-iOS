"""Client interaction utilities for exteraGram plugins."""

import _ios_bridge
from typing import Any, Optional


def get_client_version() -> str:
    """Return the client application version."""
    return "12.9.2"


def get_current_account() -> int:
    """Return the current active account index."""
    return 0


def send_message(peer_id: int, text: str, reply_to_msg_id: int = 0) -> None:
    """Send a text message to the specified peer."""
    try:
        _ios_bridge.send_message(int(peer_id), str(text), int(reply_to_msg_id))
    except Exception:
        pass


def edit_message(peer_id: int, message_id: int, text: str) -> None:
    """Edit an existing message."""
    try:
        _ios_bridge.edit_message(int(peer_id), int(message_id), str(text))
    except Exception:
        pass


def delete_messages(peer_id: int, message_ids: list[int], for_all: bool = True) -> None:
    """Delete messages by ID."""
    try:
        _ios_bridge.delete_messages(int(peer_id), [int(m) for m in message_ids], bool(for_all))
    except Exception:
        pass


def open_chat(peer_id: int) -> None:
    """Navigate to the chat screen with peer_id."""
    try:
        _ios_bridge.open_chat(int(peer_id))
    except Exception:
        pass
