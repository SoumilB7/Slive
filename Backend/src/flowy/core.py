from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from time import perf_counter
from typing import Any


DEFAULT_MODEL_ID = "google/gemma-4-E2B-it"
MAX_AUDIO_SECONDS = 30.0


@dataclass(frozen=True)
class TranslationResult:
    text: str
    elapsed_seconds: float
    model_id: str


def build_translation_prompt(source_language: str, target_language: str) -> str:
    return f"""Translate the spoken audio from {source_language} into {target_language}.

Requirements:
- Output only the {target_language} translation.
- Preserve the complete meaning; do not summarize.
- Use natural paragraphs and correct punctuation.
- Preserve names, numbers, dates, currencies, and technical terminology.
- Remove filler words only when they add no meaning.
- Do not explain, comment, label the output, or add information.
- If a passage is unintelligible, write [inaudible] rather than guessing."""


def build_messages(audio_path: Path, source_language: str, target_language: str) -> list[dict]:
    return [
        {
            "role": "user",
            "content": [
                {"type": "audio", "path": str(audio_path.resolve())},
                {
                    "type": "text",
                    "text": build_translation_prompt(source_language, target_language),
                },
            ],
        }
    ]


def extract_generated_text(output: Any) -> str:
    """Extract the assistant text from the Transformers pipeline response."""
    value = output
    if isinstance(value, list) and value:
        value = value[0]
    if isinstance(value, dict) and "generated_text" in value:
        value = value["generated_text"]
    if isinstance(value, list) and value:
        value = value[-1]
    if isinstance(value, dict):
        value = value.get("content", value.get("text", ""))
    if isinstance(value, list):
        text_blocks = [
            str(block.get("text", ""))
            for block in value
            if isinstance(block, dict) and block.get("type") == "text"
        ]
        value = "\n".join(text_blocks)
    if not isinstance(value, str) or not value.strip():
        raise RuntimeError(f"Unexpected or empty model response: {output!r}")
    return value.strip()


class GemmaTranslator:
    def __init__(
        self,
        model_id: str = DEFAULT_MODEL_ID,
        device: str = "auto",
        dtype: str = "auto",
    ) -> None:
        self.model_id = model_id
        self.device = device
        self.dtype = dtype
        self._pipe: Any = None

    def load(self) -> None:
        if self._pipe is not None:
            return

        from transformers import pipeline

        kwargs: dict[str, Any] = {
            "task": "any-to-any",
            "model": self.model_id,
            "dtype": self.dtype,
        }
        if self.device == "auto":
            kwargs["device_map"] = "auto"
        else:
            kwargs["device"] = self.device
        self._pipe = pipeline(**kwargs)

    def translate(
        self,
        audio_path: Path,
        source_language: str,
        target_language: str,
        max_new_tokens: int = 512,
    ) -> TranslationResult:
        if not audio_path.is_file():
            raise FileNotFoundError(f"Audio file does not exist: {audio_path}")
        self.load()
        started = perf_counter()
        output = self._pipe(
            text=build_messages(audio_path, source_language, target_language),
            max_new_tokens=max_new_tokens,
            do_sample=False,
            return_full_text=False,
        )
        return TranslationResult(
            text=extract_generated_text(output),
            elapsed_seconds=perf_counter() - started,
            model_id=self.model_id,
        )

