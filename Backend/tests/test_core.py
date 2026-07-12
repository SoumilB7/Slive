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

