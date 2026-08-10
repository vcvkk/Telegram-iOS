"""File and directory utilities for exteraGram plugins."""

import os
import shutil
from typing import Optional


def get_app_files_dir() -> str:
    """Return the Documents/EGPlugins directory for persistent data."""
    path = os.path.expanduser("~/Documents/EGPlugins")
    os.makedirs(path, exist_ok=True)
    return path


def get_cache_dir() -> str:
    """Return the Library/Caches/EGPlugins directory."""
    path = os.path.expanduser("~/Library/Caches/EGPlugins")
    os.makedirs(path, exist_ok=True)
    return path


def get_plugin_dir(plugin_id: str) -> str:
    """Return the specific storage directory for a plugin."""
    path = os.path.join(get_app_files_dir(), "data", plugin_id)
    os.makedirs(path, exist_ok=True)
    return path


def read_file(path: str, binary: bool = False):
    """Read full content of a file."""
    mode = "rb" if binary else "r"
    with open(path, mode) as f:
        return f.read()


def write_file(path: str, data, binary: bool = False) -> None:
    """Write data to file, creating parent directories if needed."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if binary else "w"
    with open(path, mode) as f:
        f.write(data)


def delete_file(path: str) -> bool:
    """Delete a file or directory safely."""
    try:
        if os.path.isdir(path):
            shutil.rmtree(path)
        elif os.path.exists(path):
            os.remove(path)
        return True
    except Exception:
        return False


def list_files(path: str) -> list[str]:
    """List files in directory."""
    if os.path.exists(path) and os.path.isdir(path):
        return os.listdir(path)
    return []
