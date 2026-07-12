"""Local (on-device) inference for downloaded Hugging Face models.

Loads a cached model with `transformers` and runs it for the two things Slive
needs:

  * **chat** — text plus an optional screenshot image (the Assistant), and
  * **transcribe** — audio in, text out (Ground Truth).

Capability comes from the model's *config* (vision_config / audio_config), not
from whether a processor class happens to import — a missing helper library
must surface as its real error, never silently demote a multimodal model to
text-only (gemma-4-E2B-it once read as "can't see images" because torchvision
was absent). Asking a text-only model to see or hear raises a clean,
user-facing error instead of crashing.

Weights load int8-quantized by default (torchao weight-only — roughly half the
resident RAM of bf16) behind a user toggle, under a user-set memory limit:
models that can't plausibly fit are refused before any bytes load, the MPS
allocator is capped so a miss raises instead of swap-storming the machine, and
an OOM evicts the model and reports the limit that was hit.

One model stays resident at a time — these are slow to load and heavy in RAM
on a 16GB Mac — so switching models (or flipping quantization) evicts the
previous one. Everything here is synchronous and blocking; callers run it in a
threadpool.
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


DEFAULT_MEM_GB = 10.0

#: Rough resident-RAM multipliers on on-disk (bf16 safetensors) size. Quantized
#: keeps embeddings/norms/vision towers in bf16 — only linears drop to int8 —
#: so embedding-heavy architectures (Gemma E-series per-layer embeddings) save
#: well under half; 0.72 matches measured gemma-4-E2B-it (~7 GB from 9.6 GB).
_QUANTIZED_DISK_FACTOR = 0.72
_FULL_DISK_FACTOR = 1.0
#: Activations, KV cache, vision/audio tower forward, allocator slack.
_OVERHEAD_GB = 1.5


@dataclass
class _Loaded:
    repo_id: str
    quantized: bool
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


def _snapshot_bytes(repo_id: str) -> int:
    """On-disk size of the cached repo (its blobs — each stored once)."""
    from huggingface_hub import constants

    blobs = Path(constants.HF_HUB_CACHE) / f"models--{repo_id.replace('/', '--')}" / "blobs"
    try:
        return sum(f.stat().st_size for f in blobs.iterdir() if f.is_file())
    except OSError:
        return 0


def _apply_memory_cap(device: str, mem_gb: float) -> None:
    """Cap the MPS allocator so exceeding the limit raises a catchable OOM
    instead of paging the whole machine out."""
    if device != "mps":
        return
    import torch

    try:
        recommended = torch.mps.recommended_max_memory()
        if recommended > 0:
            fraction = min(max(mem_gb * 1024**3 / recommended, 0.1), 2.0)
            torch.mps.set_per_process_memory_fraction(fraction)
    except (AttributeError, RuntimeError):
        pass  # older torch — the pre-load estimate gate still protects us


def _check_fits(repo_id: str, quantized: bool, mem_gb: float) -> None:
    disk = _snapshot_bytes(repo_id)
    if disk <= 0:
        return  # unknown size — let the allocator cap catch a real overrun
    factor = _QUANTIZED_DISK_FACTOR if quantized else _FULL_DISK_FACTOR
    est_gb = disk / 1024**3 * factor + _OVERHEAD_GB
    if est_gb > mem_gb:
        how = "quantized" if quantized else "unquantized"
        hint = (
            "raise the memory limit or pick a smaller model"
            if quantized
            else "turn Quantized on, raise the memory limit, or pick a smaller model"
        )
        raise LocalInferenceError(
            f"{repo_id} needs roughly {est_gb:.1f} GB {how} but the memory "
            f"limit is {mem_gb:.0f} GB — {hint}."
        )


def _is_oom(exc: Exception) -> bool:
    text = str(exc).lower()
    return "out of memory" in text or "insufficient memory" in text


def _load(repo_id: str, token: str | None, quantized: bool, mem_gb: float) -> _Loaded:
    global _current
    with _lock:
        if _current is not None and (_current.repo_id, _current.quantized) == (repo_id, quantized):
            _apply_memory_cap("mps", mem_gb)   # limit may have moved — re-apply
            return _current
        if _current is not None:               # free the previous model first
            _current = None
            _free_accelerator()

        from transformers import (
            AutoConfig,
            AutoModelForCausalLM,
            AutoModelForImageTextToText,
            AutoProcessor,
            AutoTokenizer,
        )

        device, dtype = _device_and_dtype()
        tok = token or None

        # Capability is declared by the model's config — a processor that fails
        # to import must NOT silently demote a multimodal model to text-only.
        try:
            config = AutoConfig.from_pretrained(repo_id, token=tok)
        except Exception as exc:
            raise LocalInferenceError(
                f"Couldn't read {repo_id}'s config: {_short(exc)}"
            ) from exc
        supports_image = getattr(config, "vision_config", None) is not None
        supports_audio = getattr(config, "audio_config", None) is not None
        multimodal = supports_image or supports_audio

        if multimodal:
            try:
                processor = AutoProcessor.from_pretrained(repo_id, token=tok)
            except Exception as exc:
                raise LocalInferenceError(
                    f"{repo_id} is multimodal but its processor failed to load "
                    f"({_short(exc)}) — the backend may be missing a helper "
                    f"library it needs."
                ) from exc
        else:
            try:
                processor = AutoTokenizer.from_pretrained(repo_id, token=tok)
            except Exception as exc:
                raise LocalInferenceError(
                    f"Couldn't load a tokenizer for {repo_id}: {_short(exc)}"
                ) from exc

        _check_fits(repo_id, quantized, mem_gb)

        kwargs: dict = {"token": tok, "dtype": dtype}
        if quantized:
            from torchao.quantization import Int8WeightOnlyConfig
            from transformers import TorchAoConfig

            # Quantize on the CPU while loading: converting straight onto MPS
            # transiently holds bf16 AND int8 copies and trips the allocator
            # cap mid-load (seen with gemma-4-E2B-it). CPU conversion streams
            # shard-by-shard; the half-size result then moves to the GPU.
            kwargs["quantization_config"] = TorchAoConfig(quant_type=Int8WeightOnlyConfig())

        # Multimodal conditional-generation class first (covers vision + Gemma
        # 3n/4 audio), then plain causal-LM for text-only models.
        model = None
        last_exc: Exception | None = None
        for loader in (AutoModelForImageTextToText, AutoModelForCausalLM):
            try:
                model = loader.from_pretrained(repo_id, **kwargs)
                break
            except Exception as exc:  # noqa: BLE001 - try the next class
                last_exc = exc
                if _is_oom(exc):
                    break
                continue
        if model is None:
            _free_accelerator()
            if last_exc is not None and _is_oom(last_exc):
                raise LocalInferenceError(
                    f"Ran out of memory loading {repo_id} under the "
                    f"{mem_gb:.0f} GB limit — raise the limit or pick a "
                    f"smaller model."
                ) from last_exc
            raise LocalInferenceError(
                f"Couldn't load {repo_id} for generation "
                f"({_short(last_exc) if last_exc else 'no loader matched'}) — "
                f"it may not be a text-generation model."
            )
        model.to(device)
        model.eval()
        # Cap the accelerator only after the weights land — generation gets the
        # full limit; the load transient stayed off the GPU entirely.
        _apply_memory_cap(device, mem_gb)

        _current = _Loaded(
            repo_id, quantized, model, processor, supports_image, supports_audio, multimodal
        )
        return _current


def _free_accelerator() -> None:
    """Drop refs and return freed weights to the OS (gc alone leaves the MPS
    allocator holding the pool)."""
    gc.collect()
    try:
        import torch

        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except Exception:  # noqa: BLE001 - freeing is best-effort
        pass


def unload() -> None:
    """Free the resident model (e.g. on app quit)."""
    global _current
    with _lock:
        _current = None
        _free_accelerator()


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
    try:
        with torch.no_grad():
            generated = loaded.model.generate(
                **inputs, max_new_tokens=max_tokens, do_sample=False
            )
    except RuntimeError as exc:
        if _is_oom(exc):
            unload()
            raise LocalInferenceError(
                "Ran out of memory while generating — raise the memory limit "
                "in Settings, or pick a smaller model."
            ) from exc
        raise
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
    quantized: bool = True,
    mem_gb: float = DEFAULT_MEM_GB,
) -> str:
    """Assistant answer from a local model: text plus optional screenshot(s)."""
    loaded = _load(repo_id, token, quantized, mem_gb)
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
    quantized: bool = True,
    mem_gb: float = DEFAULT_MEM_GB,
) -> str:
    """Verbatim transcription from a local audio-capable model, following the
    same English-only / disfluency rules as the cloud ground-truth path."""
    loaded = _load(repo_id, token, quantized, mem_gb)
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
