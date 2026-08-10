"""Class lookup helper for Android reflection compatibility."""

import java

def find_class(class_name: str):
    """Resolve Java/Android class through Chaquopy emulation."""
    return java.jclass(class_name)

def get_class(class_name: str):
    return find_class(class_name)
