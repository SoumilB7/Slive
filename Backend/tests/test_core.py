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
