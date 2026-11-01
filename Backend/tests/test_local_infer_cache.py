"""A local model missing from the HF cache fails fast, never downloads."""

import pytest
from huggingface_hub import constants

from flowy import local_infer


def test_missing_model_is_refused_before_any_load(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(constants, "HF_HUB_CACHE", str(tmp_path))
    monkeypatch.setattr(local_infer, "_current", None)
    with pytest.raises(local_infer.LocalInferenceError, match="isn't downloaded"):
        local_infer._load("someone/not-here", None, True, 10.0)


def test_missing_model_keeps_the_resident_one(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(constants, "HF_HUB_CACHE", str(tmp_path))
    resident = local_infer._Loaded("a/b", True, object(), object(), False, False, False)
    monkeypatch.setattr(local_infer, "_current", resident)
    with pytest.raises(local_infer.LocalInferenceError):
        local_infer._load("someone/not-here", None, True, 10.0)
    assert local_infer._current is resident
