"""Small text helpers shared by every module that reports an error."""

from __future__ import annotations


def error_text(exc: BaseException, limit: int | None = None) -> str:
    """An exception's text for the app — never blank (a bare ``TimeoutError()``
    stringifies to "" and used to show the user an empty error), optionally
    clipped to ``limit`` characters."""
    text = str(exc).strip() or type(exc).__name__
    return text if limit is None else text[:limit]


def truncate(text: str, limit: int = 500) -> str:
    """Clip a response body for error messages so logs stay readable."""
    if len(text) <= limit:
        return text
    return text[:limit] + "..."
