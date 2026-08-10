"""
TL hook and lifecycle event registration utilities. API-compatible with Android SDK.

Usage:
    from hook_utils import add_tl_hook, add_event_hook

    # Mutating hook — modify params dict in-place before dispatch
    add_tl_hook("messages.sendReaction", on_send_reaction)

    def on_send_reaction(params):
        params["big"] = True

    # Lifecycle notification — params are read-only snapshots
    add_event_hook("chat.opened", on_chat_opened)

    def on_chat_opened(params):
        print("Opened chat", params.get("peer_id"))

Available events (all use add_event_hook / add_tl_hook interchangeably):
  Mutating (params written back, synchronous):
    messages.sendReaction      — params: peer_id, reaction; set big=True for large animation
    messages.interceptMessage  — params: peer_id, text; set cancel=True to suppress the send
  Notification (async snapshots, params read-only):
    messages.sendMessage       — params: peer_id, count
    messages.editMessage       — params: peer_id, message_id, text
    messages.deleteMessages    — params: message_ids, delete_for_everyone
    messages.forwardMessages   — params: peer_id, count
    messages.pinMessage        — params: peer_id, message_id, pinned (bool)
    messages.readHistory       — params: peer_id, max_id
    chat.opened                — params: peer_id  (fires on viewDidAppear)
    chat.closed                — params: peer_id  (fires on viewWillDisappear)

  ObjC-swizzlable methods (use add_method_hook from hook_utils):
    ChatControllerImpl  viewWillAppear:        — chat screen will appear
    ChatControllerImpl  viewDidAppear:         — chat screen appeared
    ChatControllerImpl  viewWillDisappear:     — chat screen will disappear
    ChatControllerImpl  leftNavigationButtonAction  — back/close button
    ChatControllerImpl  rightNavigationButtonAction — right nav button
    ChatControllerImpl  moreButtonPressed           — "…" more menu
    TelegramUI.ChatListController  viewDidAppear:   — chat list appeared
    TelegramUI.ChatListController  editPressed      — edit mode activated
"""

import _ios_bridge

# ---------------------------------------------------------------------------
# TL hooks  (mutating, synchronous)
# ---------------------------------------------------------------------------

def add_tl_hook(tl_type: str, callback) -> None:
    """
    Register callback for a TL message type or lifecycle event name.

    callback(params: dict) is called before dispatch for mutating hooks, or
    asynchronously as a notification for lifecycle events.
    Modify params in-place to change outgoing parameters.
    """
    _ios_bridge.add_tl_hook(tl_type, callback)


# ---------------------------------------------------------------------------
# Generic lifecycle event hooks  (notification, async)
# ---------------------------------------------------------------------------

def add_event_hook(event_name: str, callback) -> None:
    """
    Register callback for a named lifecycle event.

    Identical to add_tl_hook — both register into the same hook table.
    This alias exists for clarity: use add_tl_hook for TL protocol messages
    and add_event_hook for UI/lifecycle events like chat.opened.

    callback(params: dict) receives a snapshot dict (read-only for async events).
    """
    _ios_bridge.add_tl_hook(event_name, callback)


# ---------------------------------------------------------------------------
# Android compatibility: find_class maps Android class names to ObjC/Python
# ---------------------------------------------------------------------------

def find_class(module: str, name: str):
    """
    Android: finds a Java class.
    iOS: returns a Python callable that no-ops, preserving source compatibility.
    """
    class _AndroidClassStub:
        _name = f"{module}.{name}"

        def __getattr__(self, item):
            return lambda *args, **kwargs: None

    return _AndroidClassStub()


# ---------------------------------------------------------------------------
# Android compatibility: method hooks via ObjC swizzling
# ---------------------------------------------------------------------------

def add_method_hook(class_name: str, method_name: str, before=None, after=None) -> None:
    """
    Android: hooks a Java method via reflection.
    iOS: hooks an ObjC instance method via the runtime swizzler.

    The before/after callbacks are called with no arguments (notification style).
    Extra method arguments are preserved via ARM64 register conventions so the
    original implementation receives them unmodified.

    Raises ValueError if the class or method does not exist at call time.
    """
    _ios_bridge.add_method_hook(class_name, method_name, before, after)
