"""
File system utilities for plugins. API-compatible with Android SDK.

Calling convention (mirrors Android):
    read_json(plugin_id, filename)         -> dict | None
    write_json(plugin_id, filename, data)
    read_file(plugin_id, filename)         -> str | None
    write_file(plugin_id, filename, text)
    get_plugin_data_dir(plugin_id)         -> str  (creates dir if needed)
"""

import os
import _ios_bridge


def get_plugin_data_dir(plugin_id: str) -> str:
    """Return (and create) the writable data directory for the plugin."""
    try:
        path = _ios_bridge.get_plugin_data_dir(plugin_id)
    except AttributeError:
        docs = os.path.expanduser("~/Documents")
        path = os.path.join(docs, "EGPlugins", ".data", plugin_id)
    os.makedirs(path, exist_ok=True)
    return path


def read_json(plugin_id: str, filename: str):
    """Read and parse a JSON file from the plugin's data directory.
    Returns None if the file does not exist or is not valid JSON."""
    import json
    path = os.path.join(get_plugin_data_dir(plugin_id), filename)
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def write_json(plugin_id: str, filename: str, data, indent: int = 2) -> None:
    """Write data as JSON to the plugin's data directory."""
    import json
    path = os.path.join(get_plugin_data_dir(plugin_id), filename)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)


def read_file(plugin_id: str, filename: str, encoding: str = "utf-8"):
    """Read a text file from the plugin's data directory.
    Returns None if the file does not exist."""
    path = os.path.join(get_plugin_data_dir(plugin_id), filename)
    try:
        with open(path, "r", encoding=encoding) as f:
            return f.read()
    except (FileNotFoundError, OSError):
        return None


def write_file(plugin_id: str, filename: str, content: str,
               encoding: str = "utf-8") -> None:
    """Write a text file to the plugin's data directory."""
    path = os.path.join(get_plugin_data_dir(plugin_id), filename)
    with open(path, "w", encoding=encoding) as f:
        f.write(content)
