"""Metadata parser for exteraGram plugins."""

import re
from typing import Optional


class PluginMetadata:
    def __init__(self, name: str, author: str = "", version: str = "1.0", description: str = "",
                 plugin_id: str = "", icon: str = "", min_sdk: str = "1.0"):
        self.name = name
        self.author = author
        self.version = version
        self.description = description
        self.id = plugin_id or re.sub(r"[^A-Za-z0-9_]", "_", name).lower()
        self.icon = icon
        self.min_sdk = min_sdk

    def to_dict(self) -> dict[str, str]:
        return {
            "name": self.name,
            "author": self.author,
            "version": self.version,
            "description": self.description,
            "id": self.id,
            "icon": self.icon,
            "min_sdk": self.min_sdk,
        }


def parse_metadata(content: str) -> Optional[PluginMetadata]:
    """Extract plugin metadata from headers or docstring."""
    name = ""
    author = ""
    version = "1.0"
    description = ""
    plugin_id = ""
    icon = ""
    min_sdk = "1.0"

    for line in content.splitlines():
        line = line.strip()
        if not line or not (line.startswith("#") or line.startswith("//")):
            if not line.startswith('"""') and not line.startswith("'''"):
                break
        
        # Clean comment prefix
        cleaned = re.sub(r"^[#/\s*]+", "", line).strip()
        if ":" in cleaned:
            k, v = cleaned.split(":", 1)
            k, v = k.strip().lower(), v.strip()
            if k in ("name", "title"):
                name = v
            elif k in ("author", "creator"):
                author = v
            elif k == "version":
                version = v
            elif k in ("description", "desc"):
                description = v
            elif k in ("id", "plugin_id"):
                plugin_id = v
            elif k == "icon":
                icon = v
            elif k in ("min_sdk", "minsdk", "sdk"):
                min_sdk = v

    if name:
        return PluginMetadata(name, author, version, description, plugin_id, icon, min_sdk)
    return None
