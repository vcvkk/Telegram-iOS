"""Utility helpers for Elyx plugins."""

from typing import Any, Callable


class LazyDict(dict):
    """Dictionary that evaluates callable values lazily upon access."""

    def __getitem__(self, key):
        val = super().__getitem__(key)
        if callable(val):
            val = val()
            self[key] = val
        return val


def gen(target_class: Any, method_name: str = "run", returns_value: bool = False) -> Callable:
    """Generates an adapter wrapper matching target Java interface signature."""
    def decorator(fn):
        return fn
    return decorator


def gen2(target_class: Any, method_name: str = "run") -> Callable:
    return gen(target_class, method_name)


def mvel_execute(expression: str, context: dict[str, Any] = None) -> Any:
    """Executes a simple expression within the given context."""
    return None
