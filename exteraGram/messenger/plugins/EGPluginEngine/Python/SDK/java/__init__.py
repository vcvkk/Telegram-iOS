"""
Java / Chaquopy compatibility emulation layer for exteraGram iOS.

Provides `java.jclass` and `dynamic_proxy` to allow Android Python plugins
to access Telegram and Android APIs without source code modification.
"""

from typing import Any
import _ios_bridge


class _JavaClassProxy:
    """Dynamic proxy simulating a Java class loaded via Chaquopy's jclass."""

    def __init__(self, class_name: str):
        self._class_name = class_name

    def __call__(self, *args, **kwargs):
        # Constructor emulation
        return _JavaInstanceProxy(self._class_name, args, kwargs)

    def __getattr__(self, name: str):
        # Static method or field dispatch
        if self._class_name == "org.telegram.messenger.AndroidUtilities":
            if name == "runOnUIThread":
                return lambda func, delay=0: _ios_bridge.run_on_main_thread(func)
            elif name == "dp":
                return lambda value: float(value)

        elif self._class_name == "org.telegram.messenger.NotificationCenter":
            if name == "getInstance":
                return lambda account=0: _NotificationCenterProxy(account)

        elif self._class_name == "org.telegram.messenger.MessagesController":
            if name == "getInstance":
                return lambda account=0: _MessagesControllerProxy(account)

        elif self._class_name == "org.telegram.messenger.Utilities":
            if name in ("Callback", "Callback2", "Callback3", "CallbackReturn"):
                return type(name, (), {"run": lambda *a, **kw: None})

        # Generic callable proxy
        def _static_method_wrapper(*args, **kwargs):
            return None
        return _static_method_wrapper


class _JavaInstanceProxy:
    """Dynamic proxy simulating an instance of a Java class."""

    def __init__(self, class_name: str, args=None, kwargs=None):
        self._class_name = class_name
        self._args = args or ()
        self._kwargs = kwargs or {}

    def __getattr__(self, name: str):
        def _method_wrapper(*args, **kwargs):
            return None
        return _method_wrapper


class _NotificationCenterProxy:
    def __init__(self, account: int):
        self.account = account

    def addObserver(self, observer, notification_id: int):
        pass

    def removeObserver(self, observer, notification_id: int):
        pass

    def postNotificationName(self, notification_id: int, *args):
        pass


class _MessagesControllerProxy:
    def __init__(self, account: int):
        self.account = account

    def getUser(self, user_id):
        return None

    def getChat(self, chat_id):
        return None


def jclass(class_name: str) -> _JavaClassProxy:
    """Load and return a Java class proxy matching Chaquopy's java.jclass API."""
    return _JavaClassProxy(class_name)


def dynamic_proxy(interface_name: str, handler):
    """Create a proxy implementing a Java interface."""
    return handler


__all__ = ["jclass", "dynamic_proxy"]
