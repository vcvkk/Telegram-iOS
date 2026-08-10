"""Asset management for Elyx plugins."""

import os
from typing import Any


class AssetNotFoundException(Exception):
    pass


class AssetsDirNotFoundException(Exception):
    pass


class Asset:
    """Represents a single plugin asset file."""

    def __init__(self, path: str, name: str):
        self._path = path
        self._name = name

    @property
    def path(self) -> str:
        return self._path

    @property
    def name(self) -> str:
        return self._name

    def read_bytes(self) -> bytes:
        with open(self._path, "rb") as f:
            return f.read()

    def read_text(self, encoding: str = "utf-8") -> str:
        with open(self._path, "r", encoding=encoding) as f:
            return f.read()


class Assets:
    """Provides access to assets inside a plugin's assets/ directory."""

    def __init__(self, assets_dir: str):
        self._assets_dir = assets_dir

    def get(self, name: str) -> Asset:
        path = os.path.join(self._assets_dir, name)
        if not os.path.exists(path):
            raise AssetNotFoundException(f"Asset '{name}' not found at {path}")
        return Asset(path, name)

    def exists(self, name: str) -> bool:
        return os.path.exists(os.path.join(self._assets_dir, name))

    def list(self) -> list[str]:
        if not os.path.exists(self._assets_dir):
            return []
        return os.listdir(self._assets_dir)
