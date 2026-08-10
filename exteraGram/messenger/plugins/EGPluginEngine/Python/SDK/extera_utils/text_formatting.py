"""Text and Markdown entity formatting utilities."""

def format_bold(text: str) -> str:
    return f"**{text}**"

def format_italic(text: str) -> str:
    return f"__{text}__"

def format_code(text: str) -> str:
    return f"`{text}`"

def format_spoiler(text: str) -> str:
    return f"||{text}||"

def format_link(text: str, url: str) -> str:
    return f"[{text}]({url})"
