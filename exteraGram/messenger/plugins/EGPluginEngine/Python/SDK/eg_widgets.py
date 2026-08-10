"""
Cross-platform Android-style widget API for the iOS plugin engine.

Each widget builds a dict spec; the spec tree is handed to ObjC via
_ios_bridge.show_dialog(spec) which renders it as native UIKit views
(UIStackView, UILabel, UIButton, UIView with CALayer for GradientDrawable).

OnClick callbacks are stored in a module-level dict keyed by a UUID
handle.  The spec carries the handle (a string).  When the user taps,
ObjC calls back via _ios_bridge.invoke_view_callback(handle, *args) ->
eg_widgets._invoke(handle, *args).

The same plugin source can run unchanged on Android (using real
android.widget.*) and iOS (using this emulation re-exported as
android.widget) — see Python/SDK/android/* bootstrap stubs.
"""

import uuid as _uuid
import _ios_bridge as _bridge


# ---------------------------------------------------------------------------
# Callback registry
# ---------------------------------------------------------------------------

_callbacks = {}


def _register(cb):
    if not callable(cb):
        return None
    h = _uuid.uuid4().hex
    _callbacks[h] = cb
    return h


def _invoke(handle, *args):
    """Called by ObjC view layer when a button / clickable is tapped."""
    cb = _callbacks.get(handle)
    if cb is None:
        return
    try:
        cb(*args)
    except Exception:
        import traceback
        traceback.print_exc()


# ---------------------------------------------------------------------------
# Color  (Android-compatible signatures; integers are 0xAARRGGBB)
# ---------------------------------------------------------------------------

class Color:
    BLACK   = 0xFF000000
    DKGRAY  = 0xFF444444
    GRAY    = 0xFF888888
    LTGRAY  = 0xFFCCCCCC
    WHITE   = 0xFFFFFFFF
    RED     = 0xFFFF0000
    GREEN   = 0xFF00FF00
    BLUE    = 0xFF0000FF
    YELLOW  = 0xFFFFFF00
    CYAN    = 0xFF00FFFF
    MAGENTA = 0xFFFF00FF
    TRANSPARENT = 0x00000000

    @staticmethod
    def rgb(r, g, b):
        return (0xFF << 24) | ((int(r) & 0xFF) << 16) | ((int(g) & 0xFF) << 8) | (int(b) & 0xFF)

    @staticmethod
    def argb(a, r, g, b):
        return ((int(a) & 0xFF) << 24) | ((int(r) & 0xFF) << 16) | ((int(g) & 0xFF) << 8) | (int(b) & 0xFF)


# ---------------------------------------------------------------------------
# Typeface — only the style flag is meaningful on iOS
# ---------------------------------------------------------------------------

class Typeface:
    NORMAL      = 0
    BOLD        = 1
    ITALIC      = 2
    BOLD_ITALIC = 3


# ---------------------------------------------------------------------------
# Gravity bit-flags (same values as Android)
# ---------------------------------------------------------------------------

class Gravity:
    NO_GRAVITY = 0
    LEFT   = 0x03   # = start
    RIGHT  = 0x05
    TOP    = 0x30
    BOTTOM = 0x50
    CENTER_HORIZONTAL = 0x01
    CENTER_VERTICAL   = 0x10
    CENTER = CENTER_HORIZONTAL | CENTER_VERTICAL   # 0x11


# ---------------------------------------------------------------------------
# MotionEvent (stub — touch animation is automatic on iOS)
# ---------------------------------------------------------------------------

class MotionEvent:
    ACTION_DOWN   = 0
    ACTION_UP     = 1
    ACTION_MOVE   = 2
    ACTION_CANCEL = 3


# ---------------------------------------------------------------------------
# GradientDrawable — flat or stroked rounded rectangle
# ---------------------------------------------------------------------------

class GradientDrawable:
    RECTANGLE = 0
    OVAL      = 1

    def __init__(self):
        self._spec = {
            "kind":          "drawable",
            "shape":         "rectangle",
            "color":         0,
            "corner_radius": 0.0,
            "stroke_width":  0.0,
            "stroke_color":  0,
        }

    def setShape(self, shape):
        self._spec["shape"] = "oval" if shape == self.OVAL else "rectangle"
        return self

    def setColor(self, color):
        self._spec["color"] = int(color) & 0xFFFFFFFF
        return self

    def setCornerRadius(self, r):
        self._spec["corner_radius"] = float(r)
        return self

    def setStroke(self, width, color):
        self._spec["stroke_width"] = float(width)
        self._spec["stroke_color"] = int(color) & 0xFFFFFFFF
        return self


# ---------------------------------------------------------------------------
# LayoutParams
# ---------------------------------------------------------------------------

MATCH_PARENT = -1
WRAP_CONTENT = -2


class LayoutParams:
    MATCH_PARENT = MATCH_PARENT
    WRAP_CONTENT = WRAP_CONTENT

    def __init__(self, width=WRAP_CONTENT, height=WRAP_CONTENT, weight=0):
        self._spec = {
            "width":   int(width),
            "height":  int(height),
            "weight":  float(weight),
            "margins": [0, 0, 0, 0],
        }

    def setMargins(self, l, t, r, b):
        self._spec["margins"] = [int(l), int(t), int(r), int(b)]
        return self


# ---------------------------------------------------------------------------
# View — base for all widgets
# ---------------------------------------------------------------------------

class View:
    def __init__(self, context=None):
        self._spec = self._default_spec()

    # Subclasses override
    def _default_spec(self):
        return {
            "kind":          "view",
            "layout_params": LayoutParams()._spec,
            "padding":       [0, 0, 0, 0],
        }

    def setLayoutParams(self, params):
        if hasattr(params, "_spec"):
            self._spec["layout_params"] = params._spec
        return self

    def setPadding(self, l, t, r, b):
        self._spec["padding"] = [int(l), int(t), int(r), int(b)]
        return self

    def setBackgroundColor(self, color):
        self._spec["background_color"] = int(color) & 0xFFFFFFFF
        return self

    def setBackground(self, drawable):
        if hasattr(drawable, "_spec"):
            self._spec["background_drawable"] = drawable._spec
        return self

    def setAlpha(self, alpha):
        self._spec["alpha"] = float(alpha)
        return self

    def setEnabled(self, enabled):
        self._spec["enabled"] = bool(enabled)
        return self

    def isEnabled(self):
        return self._spec.get("enabled", True)

    def setVisibility(self, v):
        # 0=visible 4=invisible 8=gone
        self._spec["visible"] = (int(v) == 0)
        return self

    def setOnClickListener(self, listener):
        cb = getattr(listener, "callback", listener)
        h = _register(cb)
        if h:
            self._spec["on_click_id"] = h
        return self

    def setOnTouchListener(self, listener):
        # iOS: ignored — tap feedback is automatic for buttons
        return self

    def setElevation(self, e):
        self._spec["elevation"] = float(e)
        return self

    def animate(self):
        return _AnimatorNoop()


class _AnimatorNoop:
    """Chainable no-op for view.animate().X().Y().start()."""
    def scaleX(self, v):       return self
    def scaleY(self, v):       return self
    def alpha(self, v):        return self
    def setDuration(self, v):  return self
    def start(self):           return self


# ---------------------------------------------------------------------------
# Space — invisible filler
# ---------------------------------------------------------------------------

class Space(View):
    def _default_spec(self):
        return {"kind": "space",
                "layout_params": LayoutParams()._spec,
                "padding": [0, 0, 0, 0]}


# ---------------------------------------------------------------------------
# TextView
# ---------------------------------------------------------------------------

class TextView(View):
    def _default_spec(self):
        return {
            "kind":          "text_view",
            "text":          "",
            "text_size":     14.0,
            "text_color":    0xFF000000,
            "typeface":      "normal",
            "gravity":       0,
            "max_lines":     0,
            "padding":       [0, 0, 0, 0],
            "layout_params": LayoutParams()._spec,
        }

    def setText(self, s):
        self._spec["text"] = "" if s is None else str(s)
        return self

    def getText(self):
        return self._spec.get("text", "")

    def setTextSize(self, sp):
        self._spec["text_size"] = float(sp)
        return self

    def setTextColor(self, color):
        self._spec["text_color"] = int(color) & 0xFFFFFFFF
        return self

    def setTypeface(self, _family=None, style=0):
        # Android: setTypeface(family, style).  Family is ignored on iOS.
        mapping = {0: "normal", 1: "bold", 2: "italic", 3: "bold_italic"}
        self._spec["typeface"] = mapping.get(int(style or 0), "normal")
        return self

    def setGravity(self, gravity):
        self._spec["gravity"] = int(gravity)
        return self

    def setLines(self, n):
        self._spec["max_lines"] = int(n)
        return self

    def setMaxLines(self, n):
        self._spec["max_lines"] = int(n)
        return self

    def setSingleLine(self, single=True):
        self._spec["max_lines"] = 1 if single else 0
        return self

    def setScaleX(self, v): self._spec["scale_x"] = float(v); return self
    def setScaleY(self, v): self._spec["scale_y"] = float(v); return self


# ---------------------------------------------------------------------------
# Button — TextView with default button styling
# ---------------------------------------------------------------------------

class Button(TextView):
    def _default_spec(self):
        spec = super()._default_spec()
        spec["kind"]       = "button"
        spec["text_size"]  = 14.0
        spec["text_color"] = 0xFFFFFFFF
        spec["typeface"]   = "bold"
        spec["gravity"]    = Gravity.CENTER
        return spec


# ---------------------------------------------------------------------------
# LinearLayout
# ---------------------------------------------------------------------------

class LinearLayout(View):
    VERTICAL   = 1
    HORIZONTAL = 0
    LayoutParams = LayoutParams   # nested-class compatibility

    def _default_spec(self):
        return {
            "kind":          "linear_layout",
            "orientation":   "horizontal",
            "gravity":       0,
            "children":      [],
            "padding":       [0, 0, 0, 0],
            "layout_params": LayoutParams()._spec,
        }

    def setOrientation(self, o):
        if isinstance(o, str):
            self._spec["orientation"] = o
        else:
            self._spec["orientation"] = "vertical" if int(o) == self.VERTICAL else "horizontal"
        return self

    def setGravity(self, gravity):
        self._spec["gravity"] = int(gravity)
        return self

    def addView(self, view):
        if hasattr(view, "_spec"):
            self._spec["children"].append(view._spec)
        return self

    def removeAllViews(self):
        self._spec["children"] = []
        return self


# ---------------------------------------------------------------------------
# ImageView — displays a PNG/JPEG from a file path
# ---------------------------------------------------------------------------

class ImageView(View):
    def _default_spec(self):
        return {
            "kind":          "image_view",
            "path":          "",
            "layout_params": LayoutParams()._spec,
            "padding":       [0, 0, 0, 0],
        }

    def setImagePath(self, path):
        self._spec["path"] = str(path) if path else ""
        return self

    def setAdjustViewBounds(self, adjust):
        self._spec["adjust_view_bounds"] = bool(adjust)
        return self


# ---------------------------------------------------------------------------
# TextUtils (stub)
# ---------------------------------------------------------------------------

class TextUtils:
    @staticmethod
    def isEmpty(s):
        return s is None or len(str(s)) == 0


# ---------------------------------------------------------------------------
# dynamic_proxy — no-op shim used by Android plugins for Listener subclassing
# ---------------------------------------------------------------------------

def dynamic_proxy(*_args, **_kwargs):
    class _ProxyBase:
        def __init__(self, *a, **k):
            pass
    return _ProxyBase


# ---------------------------------------------------------------------------
# AlertDialogBuilder — minimal: title + custom view
# ---------------------------------------------------------------------------

class AlertDialogBuilder:
    def __init__(self, context=None):
        self._spec = {"title": "", "view": None, "cancelable": True}

    def set_title(self, t):
        self._spec["title"] = str(t)
        return self

    setTitle = set_title  # Java-style alias

    def set_view(self, view):
        if hasattr(view, "_spec"):
            self._spec["view"] = view._spec
        return self

    setView = set_view

    def set_cancelable(self, c):
        self._spec["cancelable"] = bool(c)
        return self

    setCancelable = set_cancelable

    def set_on_dismiss(self, cb):
        """Called when dialog is dismissed (Done button or swipe-down)."""
        h = _register(cb)
        if h:
            self._spec["on_dismiss_id"] = h
        return self

    def create(self):
        return _Dialog(self._spec)


class _Dialog:
    def __init__(self, spec):
        self._spec = spec
        self._handle = None

    def show(self):
        try:
            self._handle = _bridge.show_dialog(self._spec)
        except Exception:
            import traceback
            traceback.print_exc()
        return self

    def update_view(self, view):
        """Replace the dialog's content view in place (no flicker)."""
        if self._handle is None:
            return self
        spec = view._spec if hasattr(view, '_spec') else view
        try:
            _bridge.update_dialog(self._handle, spec)
        except Exception:
            import traceback
            traceback.print_exc()
        return self

    def dismiss(self):
        try:
            if self._handle is not None:
                _bridge.dismiss_dialog(self._handle)
        except Exception:
            pass
        self._handle = None
        return self


# ---------------------------------------------------------------------------
# BulletinHelper — Android API used by some plugins
# ---------------------------------------------------------------------------

class BulletinHelper:
    @staticmethod
    def show_info(text, _fragment=None):
        try:
            _bridge.show_bulletin(str(text), "", "info.circle")
        except Exception:
            pass

    @staticmethod
    def show_error(text, _fragment=None):
        try:
            _bridge.show_bulletin(str(text), "", "exclamationmark.triangle.fill")
        except Exception:
            pass

    @staticmethod
    def show_success(text, _fragment=None):
        try:
            _bridge.show_bulletin(str(text), "", "checkmark.circle.fill")
        except Exception:
            pass
