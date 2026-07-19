from pathlib import Path

import pytest

from flowy.core import build_messages, build_translation_prompt, extract_generated_text


def test_prompt_names_languages_and_forbids_extra_text() -> None:
    prompt = build_translation_prompt("Hindi", "English")
    assert "from Hindi into English" in prompt
    assert "Output only the English translation" in prompt
    assert "do not summarize" in prompt


def test_messages_use_absolute_local_audio_path(tmp_path: Path) -> None:
    audio = tmp_path / "sample.wav"
    messages = build_messages(audio, "Hindi", "English")
    assert messages[0]["content"][0] == {"type": "audio", "path": str(audio.resolve())}


@pytest.mark.parametrize(
    ("response", "expected"),
    [
        ([{"generated_text": "Translated text"}], "Translated text"),
        (
            [{"generated_text": [{"role": "assistant", "content": "Translated text"}]}],
            "Translated text",
        ),
        (
            [
                {
                    "generated_text": [
                        {
                            "role": "assistant",
                            "content": [{"type": "text", "text": "Translated text"}],
                        }
                    ]
                }
            ],
            "Translated text",
        ),
    ],
)
def test_extract_generated_text(response: object, expected: str) -> None:
    assert extract_generated_text(response) == expected


def test_extract_generated_text_rejects_empty_response() -> None:
    with pytest.raises(RuntimeError):
        extract_generated_text([])



# --- Local (Hugging Face) models ---

def test_list_cached_models_shape():
    from flowy.local import list_cached_models
    models = list_cached_models()
    assert isinstance(models, list)
    for m in models:
        assert set(m) >= {"repo_id", "size_bytes", "nb_files", "last_modified"}
        assert isinstance(m["size_bytes"], int)
    # Sorted largest-first.
    sizes = [m["size_bytes"] for m in models]
    assert sizes == sorted(sizes, reverse=True)


def test_download_job_lifecycle():
    from flowy.local import start_download, download_status
    # Unresolvable repo → the job reports error, never crashes.
    job_id = start_download("this-owner/definitely-does-not-exist-xyz", None)
    assert download_status(job_id) is not None
    assert download_status("nope") is None


def test_download_endpoint_rejects_bad_id():
    from fastapi.testclient import TestClient
    from flowy.server import app
    client = TestClient(app)
    r = client.post("/local/download", json={"repo_id": "not-valid"})
    assert r.status_code == 400
    assert "error" in r.json()


def test_transcription_guard_rejects_meta_replies() -> None:
    import pytest

    from flowy.assistant import _guard_transcription

    for reply in (
        "Understood. Please share the audio or let me know how to proceed.",
        "I can transcribe it as requested once you've provided the audio file.",
        "Here is the transcription: hello world",
    ):
        with pytest.raises(ValueError, match="instead of transcribing"):
            _guard_transcription(reply)

    # Real transcripts pass through untouched — including ones that merely
    # mention audio late in the text (the guard only reads the head).
    ok = "Please check the recording pipeline. " + "x " * 120 + "the audio file was fine."
    assert _guard_transcription(ok) == ok
    assert _guard_transcription("Add the ability to delete one sample.") != ""


def test_transcribe_fallback_model_mapping() -> None:
    from flowy.assistant import _transcribe_fallback_models as fallback

    assert fallback("gpt-audio-mini") == ["gpt-4o-mini-transcribe", "whisper-1"]
    assert fallback("gpt-audio") == ["gpt-4o-transcribe", "whisper-1"]
    # A pick that already is an endpoint model leads verbatim.
    assert fallback("gpt-4o-transcribe")[0] == "gpt-4o-transcribe"
    assert fallback("whisper-1") == ["whisper-1", "gpt-4o-transcribe"]
    # No duplicates, whisper-1 always reachable.
    for pick in ("gpt-audio-mini", "gpt-4o-mini-transcribe", "anything-else"):
        models = fallback(pick)
        assert len(models) == len(set(models)) and "whisper-1" in models


def test_audio_payload_validation() -> None:
    import base64

    import pytest

    from flowy.assistant import _validate_audio_payload

    real = base64.b64encode(b"\x00" * 32_000).decode()   # ~1s of canonical WAV
    assert _validate_audio_payload(real) == 32_000

    tiny = base64.b64encode(b"RIFF" + b"\x00" * 40).decode()   # header-only WAV
    with pytest.raises(ValueError, match="empty or truncated"):
        _validate_audio_payload(tiny)

    with pytest.raises(ValueError, match="not valid base64"):
        _validate_audio_payload("!!!not-base64!!!")
