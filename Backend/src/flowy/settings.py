"""Every environment variable and on-disk location the server uses, in one place.

``Settings.from_env()`` is a cheap snapshot. Path helpers elsewhere build a
fresh one per call rather than caching at import, so an override set after
import (the app's launch environment, a test's ``monkeypatch.setenv``) is
always honoured.

Environment:
    SLIVE_PARENT_PID           the app's pid — the server exits when it dies
    SLIVE_PROCESS_GROUP=1      lead our own process group (the app signals it)
    SLIVE_TRAINING_DIR         training store (the Swift app writes it)
    SLIVE_TRAINING_OUTPUT_DIR  fine-tuning run folders
    SLIVE_CUSTOM_MODELS_DIR    installed fine-tuned WhisperKit models
    SLIVE_WHISPERKIT_TOOLS     whisperkittools venv + xcrun shim
    WHISPERKIT_GENERATE_MODEL  explicit converter executable
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

HOST = "127.0.0.1"
PORT = 50711


def app_support_dir() -> Path:
    """~/Library/Application Support/Slive — the Swift app's data folder."""
    return Path.home() / "Library" / "Application Support" / "Slive"


def _dir(environ: Mapping[str, str], name: str, default: Path) -> Path:
    override = environ.get(name)
    return Path(override).expanduser() if override else default


def _pid(raw: str | None) -> int:
    try:
        return int(raw or "")
    except ValueError:
        return 0


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    app_support: Path
    training_dir: Path
    training_output_dir: Path
    custom_models_dir: Path
    whisperkit_tools_dir: Path
    #: Explicit converter path; empty = the tools venv, then PATH.
    whisperkit_generate_model: str
    #: The app's pid (0 = not launched by the app, nothing to watch).
    parent_pid: int
    #: Launched by the app: lead our own process group so its stop() signals
    #: us AND our children (the training converter) as one unit.
    own_process_group: bool

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if environ is None else environ
        support = app_support_dir()
        return cls(
            host=HOST,
            port=PORT,
            app_support=support,
            training_dir=_dir(env, "SLIVE_TRAINING_DIR", support / "training"),
            training_output_dir=_dir(env, "SLIVE_TRAINING_OUTPUT_DIR", support / "training-runs"),
            custom_models_dir=_dir(env, "SLIVE_CUSTOM_MODELS_DIR", support / "Models" / "Custom"),
            whisperkit_tools_dir=_dir(
                env, "SLIVE_WHISPERKIT_TOOLS", support / "tools" / "whisperkittools"
            ),
            whisperkit_generate_model=env.get("WHISPERKIT_GENERATE_MODEL") or "",
            parent_pid=_pid(env.get("SLIVE_PARENT_PID")),
            own_process_group=env.get("SLIVE_PROCESS_GROUP") == "1",
        )
