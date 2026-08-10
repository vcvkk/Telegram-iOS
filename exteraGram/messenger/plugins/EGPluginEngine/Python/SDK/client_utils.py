"""
Telegram client utilities. API-compatible with Android SDK.

On Android these called Java singleton instances directly.
On iOS they go through _ios_bridge which calls into Swift/ObjC.
"""

import _ios_bridge


def get_account_id() -> int:
    """Return the active account's numeric ID."""
    try:
        return _ios_bridge.get_account_id()
    except AttributeError:
        return 0


def get_user_id() -> int:
    """Return the logged-in user's Telegram user ID."""
    try:
        return _ios_bridge.get_user_id()
    except AttributeError:
        return 0


def get_connection_state() -> str:
    """Return current connection state string."""
    try:
        return _ios_bridge.get_connection_state()
    except AttributeError:
        return "connected"


# ---------------------------------------------------------------------------
# Android stubs — kept for source compatibility
# ---------------------------------------------------------------------------

class MessagesController:
    """Stub for Android MessagesController."""

    @staticmethod
    def getInstance(account: int = 0):
        return _MessagesControllerStub()


class _MessagesControllerStub:
    def getUser(self, user_id: int): return None
    def getChat(self, chat_id: int): return None
    def getUserFull(self, user_id: int): return None
    def sendMessage(self, *args, **kwargs): pass


class ConnectionsManager:
    """Stub for Android ConnectionsManager."""

    @staticmethod
    def getInstance(account: int = 0):
        return _ConnectionsManagerStub()


class _ConnectionsManagerStub:
    def sendRequest(self, *args, **kwargs): pass
    def getConnectionState(self): return 3  # STATE_CONNECTED
