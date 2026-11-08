"""Every environment variable the server reads: unset, valid and invalid.

The documented set lives in ``flowy/settings.py``'s module docstring; the
first test fails when a variable is added there without cases here.
"""

from __future__ import annotations

import dataclasses
import re
from pathlib import Path

import pytest

from flowy import settings as settings_module
from flowy.settings import HOST, PORT, Settings

PATH_VARS = {
    "SLIVE_TRAINING_DIR": ("training_dir", ("training",)),
    "SLIVE_TRAINING_OUTPUT_DIR": ("training_output_dir", ("training-runs",)),
    "SLIVE_CUSTOM_MODELS_DIR": ("custom_models_dir", ("Models", "Custom")),
    "SLIVE_WHISPERKIT_TOOLS": ("whisperkit_tools_dir", ("tools", "whisperkittools")),
}
OTHER_VARS = {"SLIVE_PARENT_PID", "SLIVE_PROCESS_GROUP", "WHISPERKIT_GENERATE_MODEL"}
BLANKS = ["", " ", "\t", "  \n"]


def test_every_documented_variable_is_covered() -> None:
    documented = set(re.findall(r"^\s{4}([A-Z][A-Z0-9_]+)(?:=\S*)?\s", settings_module.__doc__, re.M))
    assert documented == set(PATH_VARS) | OTHER_VARS


def test_nothing_set_gives_the_documented_defaults() -> None:
    s = Settings.from_env({})
    assert (s.host, s.port) == ("127.0.0.1", 50711) == (HOST, PORT)
    assert s.app_support == Path.home() / "Library" / "Application Support" / "Slive"
    for field, parts in PATH_VARS.values():
        assert getattr(s, field) == s.app_support.joinpath(*parts), field
    assert (s.whisperkit_generate_model, s.parent_pid, s.own_process_group) == ("", 0, False)


@pytest.mark.parametrize("name", ["PORT", "SLIVE_PORT", "FLOWY_PORT", "HOST", "SLIVE_HOST"])
def test_host_and_port_are_not_configurable(name: str) -> None:
    # The app talks to 127.0.0.1:50711 only; nothing may move the server.
    s = Settings.from_env({name: "8080" if "PORT" in name else "0.0.0.0"})
    assert (s.host, s.port) == ("127.0.0.1", 50711)


@pytest.mark.parametrize("name", sorted(PATH_VARS))
def test_path_overrides(name: str, tmp_path: Path) -> None:
    field, parts = PATH_VARS[name]
    default = Settings.from_env({}).app_support.joinpath(*parts)
    read = lambda value: getattr(Settings.from_env({name: value}), field)  # noqa: E731

    assert read(str(tmp_path)) == tmp_path
    assert read(str(tmp_path / "with space" / "ünïcode")) == tmp_path / "with space" / "ünïcode"
    assert read("~/slive-elsewhere") == Path.home() / "slive-elsewhere"
    assert read(f"{tmp_path}/") == tmp_path
    for blank in BLANKS:
        assert read(blank) == default, repr(blank)
    # Only its own field moves.
    others = {f for f, _ in PATH_VARS.values()} - {field}
    moved = Settings.from_env({name: str(tmp_path)})
    for other in others:
        assert getattr(moved, other) == getattr(Settings.from_env({}), other)


@pytest.mark.parametrize(
    ("raw", "pid"),
    [("4242", 4242), (" 4242 ", 4242), ("1", 1), ("0", 0), ("-5", 0), ("", 0), ("abc", 0),
     ("12.5", 0), ("0x10", 0), ("4242abc", 0), (None, 0)],
)
def test_parent_pid(raw: str | None, pid: int) -> None:
    env = {} if raw is None else {"SLIVE_PARENT_PID": raw}
    assert Settings.from_env(env).parent_pid == pid


@pytest.mark.parametrize(
    ("raw", "on"),
    [("1", True), ("0", False), ("true", False), ("yes", False), ("", False), (" 1", False), (None, False)],
)
def test_process_group_is_exactly_1(raw: str | None, on: bool) -> None:
    # Only the app sets it, always to "1".
    env = {} if raw is None else {"SLIVE_PROCESS_GROUP": raw}
    assert Settings.from_env(env).own_process_group is on


@pytest.mark.parametrize(("raw", "value"), [("/x/wk", "/x/wk"), ("wk", "wk"), ("", ""), ("  ", ""), (None, "")])
def test_converter_override(raw: str | None, value: str) -> None:
    env = {} if raw is None else {"WHISPERKIT_GENERATE_MODEL": raw}
    assert Settings.from_env(env).whisperkit_generate_model == value


def test_a_missing_converter_is_a_clean_error(monkeypatch, tmp_path: Path) -> None:
    from flowy.training import pipeline

    monkeypatch.setenv("WHISPERKIT_GENERATE_MODEL", str(tmp_path / "no-such-converter"))
    with pytest.raises(pipeline.ConverterUnavailable, match="not an executable"):
        pipeline.whisperkit_converter()


def test_path_helpers_read_the_environment_per_call(monkeypatch, tmp_path: Path) -> None:
    from flowy.training import pipeline, store

    helpers = {
        "SLIVE_TRAINING_DIR": store.default_store_root,
        "SLIVE_TRAINING_OUTPUT_DIR": pipeline.default_output_root,
        "SLIVE_CUSTOM_MODELS_DIR": pipeline.custom_models_root,
        "SLIVE_WHISPERKIT_TOOLS": pipeline.whisperkit_tools_root,
    }
    assert set(helpers) == set(PATH_VARS)
    for name, helper in helpers.items():
        monkeypatch.setenv(name, str(tmp_path / name))
        assert helper() == tmp_path / name
        monkeypatch.setenv(name, " ")
        assert helper() == Settings.from_env({}).app_support.joinpath(*PATH_VARS[name][1])
        monkeypatch.delenv(name)


def test_settings_are_a_frozen_snapshot() -> None:
    s = Settings.from_env({})
    with pytest.raises(dataclasses.FrozenInstanceError):
        s.port = 1  # type: ignore[misc]
