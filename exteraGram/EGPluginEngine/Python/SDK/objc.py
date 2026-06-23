"""
objc — access the Objective-C runtime from plugins.

Thin wrapper around rubicon-objc (bundled in BeewarePackages.framework) that makes
it a first-class SDK citizen, plus a few discovery helpers backed by the native
bridge. rubicon-objc is always importable because the framework is on sys.path.

Example:
    import objc
    UIScreen = objc.get_class("UIScreen")
    width = UIScreen.mainScreen.bounds.size.width

    objc.find_classes("Call")            # ["TGCallController", ...]
    objc.find_methods("UIScreen", "main")  # ["mainScreen", ...]
    objc.find_ivars("UIView")
"""

from rubicon.objc import (
    ObjCClass,
    ObjCInstance,
    send_message,
    objc_id,
    NSObject,
    NSArray,
    NSDictionary,
)

import _ios_bridge as _bridge

# rubicon.objc doesn't export NSString as a symbol; expose it via the runtime so
# `objc.NSString` works like the other Foundation collection classes.
NSString = ObjCClass("NSString")

__all__ = [
    "ObjCClass", "ObjCInstance", "send_message", "objc_id",
    "NSObject", "NSString", "NSArray", "NSDictionary",
    "get_class", "find_classes", "find_methods", "find_ivars",
]


def get_class(name):
    """Get an ObjC class by name. Example: get_class("UIScreen")."""
    return ObjCClass(name)


def find_classes(pattern):
    """Names of all registered ObjC classes containing `pattern`."""
    fn = getattr(_bridge, "list_objc_classes", None)
    if fn is None:
        return []
    return fn(pattern)


def find_methods(class_name, pattern=""):
    """Instance method selectors of `class_name` containing `pattern`."""
    fn = getattr(_bridge, "list_methods", None)
    if fn is None:
        return []
    return [m for m in fn(class_name) if pattern in m]


def find_ivars(class_name):
    """Instance variable names of `class_name`."""
    fn = getattr(_bridge, "list_ivars", None)
    if fn is None:
        return []
    return fn(class_name)
