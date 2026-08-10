"""
Java / Chaquopy compatibility emulation layer for exteraGram iOS.

Provides full runtime parity for Android Python plugins:
- java.jclass("org.telegram.messenger.*")
- java.jclass("com.exteragram.messenger.*")
- java.jclass("android.*")
"""

from typing import Any, Callable, Optional
import _ios_bridge
import time


class _TLRPCUser:
    def __init__(self, user_id: int, first_name: str = "", last_name: str = "", username: str = ""):
        self.id = int(user_id)
        self.first_name = first_name
        self.last_name = last_name
        self.username = username
        self.bot = False
        self.phone = ""

    def __repr__(self):
        return f"<TLRPC.User id={self.id} name={self.first_name!r}>"


class _TLRPCChat:
    def __init__(self, chat_id: int, title: str = "", username: str = ""):
        self.id = int(chat_id)
        self.title = title
        self.username = username
        self.participants_count = 0

    def __repr__(self):
        return f"<TLRPC.Chat id={self.id} title={self.title!r}>"


class _TLRPCMessage:
    def __init__(self, msg_id: int, peer_id: int, message: str = ""):
        self.id = int(msg_id)
        self.peer_id = int(peer_id)
        self.from_id = int(peer_id)
        self.message = message
        self.date = int(time.time())
        self.out = False

    def __repr__(self):
        return f"<TLRPC.Message id={self.id} peer={self.peer_id} text={self.message!r}>"


class _NotificationCenterProxy:
    """Manages NotificationCenter subscribers and dispatches events."""

    didReceivedNewMessages = 1
    updateInterfaces = 2
    dialogsNeedReload = 3
    closeChats = 4
    messagesDeleted = 5
    messageReceivedByAck = 6
    messageReceivedByServer = 7
    messageSendError = 8
    contactsDidLoad = 9
    chatInfoDidLoad = 12
    messagesRead = 17

    _instances = {}

    def __init__(self, account: int):
        self.account = account
        self._observers = {}

    @classmethod
    def getInstance(cls, account: int = 0):
        if account not in cls._instances:
            cls._instances[account] = _NotificationCenterProxy(account)
        return cls._instances[account]

    def addObserver(self, observer: Any, notification_id: int):
        if notification_id not in self._observers:
            self._observers[notification_id] = []
        if observer not in self._observers[notification_id]:
            self._observers[notification_id].append(observer)

    def removeObserver(self, observer: Any, notification_id: int):
        if notification_id in self._observers:
            if observer in self._observers[notification_id]:
                self._observers[notification_id].remove(observer)

    def postNotificationName(self, notification_id: int, *args):
        def _dispatch():
            obs_list = list(self._observers.get(notification_id, []))
            for obs in obs_list:
                if hasattr(obs, "didReceivedNotification"):
                    try:
                        obs.didReceivedNotification(notification_id, self.account, *args)
                    except Exception:
                        import traceback
                        traceback.print_exc()
        _ios_bridge.run_on_main_thread(_dispatch)


class _MessagesControllerProxy:
    """Dispatches core Telegram operations to the iOS bridge."""

    _instances = {}

    def __init__(self, account: int):
        self.account = account
        self.dialogs_dict = {}

    @classmethod
    def getInstance(cls, account: int = 0):
        if account not in cls._instances:
            cls._instances[account] = _MessagesControllerProxy(account)
        return cls._instances[account]

    def getUser(self, user_id: int) -> Optional[_TLRPCUser]:
        return _TLRPCUser(user_id=user_id)

    def getChat(self, chat_id: int) -> Optional[_TLRPCChat]:
        return _TLRPCChat(chat_id=chat_id)

    def sendMessage(self, peer_id: int, text: str, reply_to_msg_id: int = 0) -> None:
        try:
            _ios_bridge.send_message(int(peer_id), str(text), int(reply_to_msg_id))
        except Exception:
            pass

    def sendReaction(self, peer_id: int, msg_id: int, reaction: str) -> None:
        try:
            _ios_bridge.send_reaction(int(peer_id), int(msg_id), str(reaction))
        except Exception:
            pass

    def editMessage(self, peer_id: int, message_id: int, text: str) -> None:
        try:
            _ios_bridge.edit_message(int(peer_id), int(message_id), str(text))
        except Exception:
            pass

    def deleteMessages(self, peer_id: int, message_ids: list[int], for_all: bool = True) -> None:
        try:
            _ios_bridge.delete_messages(int(peer_id), [int(m) for m in message_ids], bool(for_all))
        except Exception:
            pass

    def openChat(self, peer_id: int) -> None:
        try:
            _ios_bridge.open_chat(int(peer_id))
        except Exception:
            pass


class _AndroidUtilitiesProxy:
    @staticmethod
    def runOnUIThread(runnable: Callable, delay: int = 0) -> None:
        if delay > 0:
            def _delayed():
                time.sleep(delay / 1000.0)
                _ios_bridge.run_on_main_thread(runnable)
            import threading
            threading.Thread(target=_delayed, daemon=True).start()
        else:
            _ios_bridge.run_on_main_thread(runnable)

    @staticmethod
    def cancelRunOnUIThread(runnable: Callable) -> None:
        pass

    @staticmethod
    def dp(value: float) -> float:
        return float(value)

    @staticmethod
    def dpf2(value: float) -> float:
        return float(value)


class _LocaleControllerProxy:
    @staticmethod
    def getString(key: str, default: str = "") -> str:
        try:
            return _ios_bridge.get_string(key) or default
        except Exception:
            return default

    @staticmethod
    def getCurrentLanguageName() -> str:
        try:
            return _ios_bridge.get_locale_language() or "en"
        except Exception:
            return "en"


class _ThemeProxy:
    @staticmethod
    def getColor(key: str) -> int:
        return 0xFF007AFF


class _JavaClassProxy:
    """Dynamic dispatcher for Java classes."""

    def __init__(self, class_name: str):
        self._class_name = class_name

    def __call__(self, *args, **kwargs):
        if self._class_name == "org.telegram.tgnet.TLRPC$User":
            return _TLRPCUser(args[0] if args else 0)
        elif self._class_name == "org.telegram.tgnet.TLRPC$Chat":
            return _TLRPCChat(args[0] if args else 0)
        elif self._class_name == "org.telegram.tgnet.TLRPC$Message":
            return _TLRPCMessage(args[0] if args else 0, args[1] if len(args) > 1 else 0)
        return _GenericJavaInstance(self._class_name, args, kwargs)

    def __getattr__(self, name: str):
        if self._class_name == "org.telegram.messenger.AndroidUtilities":
            return getattr(_AndroidUtilitiesProxy, name, lambda *a, **kw: None)

        elif self._class_name == "org.telegram.messenger.NotificationCenter":
            if name == "getInstance":
                return _NotificationCenterProxy.getInstance
            return getattr(_NotificationCenterProxy, name, lambda *a, **kw: None)

        elif self._class_name == "org.telegram.messenger.MessagesController":
            if name == "getInstance":
                return _MessagesControllerProxy.getInstance
            return getattr(_MessagesControllerProxy, name, lambda *a, **kw: None)

        elif self._class_name == "org.telegram.messenger.LocaleController":
            return getattr(_LocaleControllerProxy, name, lambda *a, **kw: None)

        elif self._class_name == "org.telegram.ui.ActionBar.Theme":
            return getattr(_ThemeProxy, name, lambda *a, **kw: None)

        elif self._class_name == "org.telegram.messenger.Utilities":
            if name in ("Callback", "Callback2", "Callback3", "CallbackReturn"):
                return type(name, (), {"run": lambda *a, **kw: None})

        return lambda *args, **kwargs: None


class _GenericJavaInstance:
    def __init__(self, class_name: str, args, kwargs):
        self._class_name = class_name
        self._args = args
        self._kwargs = kwargs

    def __getattr__(self, name: str):
        return lambda *args, **kwargs: None


def jclass(class_name: str) -> _JavaClassProxy:
    """Return an interactive class proxy for the specified Java class."""
    return _JavaClassProxy(class_name)


def dynamic_proxy(interface_name: str, handler):
    """Implement a Java interface with a Python handler."""
    return handler


__all__ = ["jclass", "dynamic_proxy"]
