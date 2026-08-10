"""Stack frame caller introspection."""

import inspect

def get_caller_module_name() -> str:
    stack = inspect.stack()
    if len(stack) > 2:
        return stack[2].frame.f_globals.get("__name__", "")
    return ""
