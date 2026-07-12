"""Local (on-device) inference for downloaded Hugging Face models.

Loads a cached model with `transformers` and runs it for the two things Slive
needs:

  * **chat** — text plus an optional screenshot image (the Assistant), and
  * **transcribe** — audio in, text out (Ground Truth).

Capability is checked up front: asking a text-only model to see an image, or a
non-audio model to hear audio, raises a clean, user-facing error instead of
crashing. One model stays resident at a time — these are slow to load and heavy
in RAM on a 16GB Mac — so switching models evicts the previous one.

Everything here is synchronous and blocking; callers run it in a threadpool.
"""

from __future__ import annotations

import base64
import binascii
import gc
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path

from flowy.assistant import TRANSCRIBE_PROMPT


class LocalInferenceError(ValueError):
    """A user-facing problem: unsupported modality, load failure, bad input."""


@dataclass
class _Loaded:
    repo_id: str
    model: object
    processor: object
    supports_image: bool
    supports_audio: bool
    multimodal: bool


_current: _Loaded | None = None
_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Loading (one resident model, evicted on switch)
# ---------------------------------------------------------------------------

def _device_and_dtype():
    import torch

    if torch.backends.mps.is_available():
        return "mps", torch.bfloat16
    return "cpu", torch.float32


def _load(repo_id: str, token: str | None) -> _Loaded:
    global _current
    with _lock:
        if _current is not None and _current.repo_id == repo_id:
            return _current
        if _current is not None:               # free the previous model first
            _current = None
            gc.collect()

        from transformers import (
            AutoModelForCausalLM,
            AutoModelForImageTextToText,
            AutoProcessor,
            AutoTokenizer,
        )

        device, dtype = _device_and_dtype()
        tok = token or None

        # A multimodal model exposes a Processor (image_processor / feature_
        # extractor); a text-only model just has a tokenizer.
        processor = None
        supports_image = supports_audio = False
        try:
            processor = AutoProcessor.from_pretrained(repo_id, token=tok)
            supports_image = getattr(processor, "image_processor", None) is not None
            supports_audio = getattr(processor, "feature_extractor", None) is not None
        except Exception:
            processor = None
        multimodal = supports_image or supports_audio
        if not multimodal:
            try:
                processor = AutoTokenizer.from_pretrained(repo_id, token=tok)
            except Exception as exc:
                raise LocalInferenceError(
                    f"Couldn't load a processor for {repo_id}: {_short(exc)}"
                ) from exc

        # Multimodal conditional-generation class first (covers vision + Gemma
        # 3n/4 audio), then plain causal-LM for text-only models.
        model = None
        for loader in (AutoModelForImageTextToText, AutoModelForCausalLM):
            try:
                model = loader.from_pretrained(repo_id, token=tok, dtype=dtype)
                break
            except Exception:  # noqa: BLE001 - try the next class
                continue
        if model is None:
            raise LocalInferenceError(
                f"Couldn't load {repo_id} for generation — it may not be a "
                f"text-generation model, or is too large for this machine."
            )
        model.to(device)
        model.eval()

        _current = _Loaded(repo_id, model, processor, supports_image, supports_audio, multimodal)
        return _current


def unload() -> None:
    """Free the resident model (e.g. on app quit)."""
    global _current
    with _lock:
        _current = None
        gc.collect()


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

def _generate(loaded: _Loaded, messages: list, max_tokens: int) -> str:
    import torch

    proc = loaded.processor
    try:
        inputs = proc.apply_chat_template(
            messages,
            add_generation_prompt=True,
            tokenize=True,
            return_dict=True,
            return_tensors="pt",
        ).to(loaded.model.device)
    except ValueError as exc:
        if "chat template" in str(exc).lower():
            raise LocalInferenceError(
                f"{loaded.repo_id} has no chat format — pick an instruction-tuned "
                f"model (its name usually ends in -it or -Instruct)."
            ) from exc
        raise

    input_len = inputs["input_ids"].shape[-1]
    with torch.no_grad():
        generated = loaded.model.generate(
            **inputs, max_new_tokens=max_tokens, do_sample=False
        )
    new_tokens = generated[0][input_len:]

    decoder = getattr(proc, "decode", None) or proc.tokenizer.decode
    return decoder(new_tokens, skip_special_tokens=True).strip()


def _text_msg(role: str, text: str, loaded: _Loaded) -> dict:
    """A single-modality message in the shape the model's template expects:
    a list of parts for multimodal models, a plain string for text-only ones."""
    if loaded.multimodal:
        return {"role": role, "content": [{"type": "text", "text": text}]}
    return {"role": role, "content": text}


# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

def chat(
    repo_id: str,
    token: str | None,
    system_prompt: str,
    history: list[dict],
    question: str,
    images_b64: list[str],
    max_tokens: int = 512,
) -> str:
    """Assistant answer from a local model: text plus optional screenshot(s)."""
    loaded = _load(repo_id, token)
    if images_b64 and not loaded.supports_image:
        raise LocalInferenceError(
            "This local model can't see images. Turn off “Attach a screenshot” "
            "in the Assistant, or pick a vision-capable model (e.g. a Gemma 3 / "
            "3n / 4 variant)."
        )

    messages: list = []
    if system_prompt:
        messages.append(_text_msg("system", system_prompt, loaded))
    for turn in history or []:
        messages.append(_text_msg(turn.get("role", "user"), turn.get("content", ""), loaded))

    temp_paths: list[str] = []
    try:
        if loaded.multimodal:
            content: list = []
            for b64 in images_b64 or []:
                path = _write_temp(b64, ".png")
                temp_paths.append(path)
                content.append({"type": "image", "path": path})
            content.append({"type": "text", "text": question})
            messages.append({"role": "user", "content": content})
        else:
            messages.append({"role": "user", "content": question})
        return _generate(loaded, messages, max_tokens)
    finally:
        for path in temp_paths:
            _remove(path)


def transcribe(
    repo_id: str,
    token: str | None,
    audio_b64: str,
    media_type: str = "audio/wav",
    max_tokens: int = 448,
) -> str:
    """Verbatim transcription from a local audio-capable model, following the
    same English-only / disfluency rules as the cloud ground-truth path."""
    loaded = _load(repo_id, token)
    if not loaded.supports_audio:
        raise LocalInferenceError(
            "This local model can't hear audio. Pick an audio-capable model "
            "(e.g. a Gemma 3n or Gemma 4 variant)."
        )
    suffix = ".mp3" if ("mp3" in media_type or "mpeg" in media_type) else ".wav"
    path = _write_temp(audio_b64, suffix)
    try:
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "audio", "path": path},
                    {"type": "text", "text": TRANSCRIBE_PROMPT},
                ],
            }
        ]
        return _generate(loaded, messages, max_tokens)
    finally:
        _remove(path)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_temp(b64: str, suffix: str) -> str:
    try:
        data = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise LocalInferenceError("Bad base64 media data.") from exc
    handle = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)  # noqa: SIM115
    handle.write(data)
    handle.close()
    return handle.name


def _remove(path: str) -> None:
    try:
        Path(path).unlink(missing_ok=True)
    except OSError:
        pass


def _short(exc: Exception) -> str:
    return (str(exc).strip() or exc.__class__.__name__)[:300]
