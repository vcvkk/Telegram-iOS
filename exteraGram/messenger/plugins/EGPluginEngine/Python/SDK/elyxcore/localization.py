"""Localization management for Elyx plugins."""

import json
import os
from typing import Any
import _ios_bridge


class Strings:
    """Manages localized strings for a plugin."""

    def __init__(self, strings_dict: dict[str, dict[str, str]] = None, default_lang: str = "en"):
        self._strings = strings_dict or {}
        self._default_lang = default_lang

    @classmethod
    def from_file(cls, path: str) -> "Strings":
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    return cls(json.load(f))
            except Exception:
                pass
        return cls({})

    @property
    def current_language(self) -> str:
        try:
            return _ios_bridge.get_locale_language() or "en"
        except Exception:
            return "en"

    def get(self, key: str, default: str = "") -> str:
        lang = self.current_language
        if lang in self._strings and key in self._strings[lang]:
            return self._strings[lang][key]
        if self._default_lang in self._strings and key in self._strings[self._default_lang]:
            return self._strings[self._default_lang][key]
        return default or key

    def __getitem__(self, key: str) -> str:
        return self.get(key)
