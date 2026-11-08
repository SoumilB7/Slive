"""Ground-truth labels by 3-way consensus.

One clip goes to two hosted transcribers in parallel — OpenAI's
``gpt-transcribe`` (steered by the user's Custom words and context) and
``whisper-1``. gpt-transcribe's transcript is the label; whisper-1 and what
Slive itself typed vote on it, and their agreement decides whether the label
is trusted for training.

Why (label bench, Oct 29 2026, Soumil's blind picks as truth): the old label
model gpt-4o-transcribe scored 13.5% WER (it randomly truncates), the best
single transcriber 1.7%, and this consensus 1.4% — each model's slips are
outvoted by the other two, and no local decode is needed.

Same per-request key model as the assistant providers: the OpenAI key travels
with the request and nothing is stored server-side.
"""

from __future__ import annotations

import asyncio
import base64
import io
import logging
import re
from typing import Any

import httpx

from flowy.errors import FatalLabel
from flowy.providers.base import TIMEOUT_SECONDS
from flowy.providers.transcription import validate_audio_payload
from flowy.util import truncate

logger = logging.getLogger("flowy.label_consensus")

TRANSCRIPTIONS_URL = "https://api.openai.com/v1/audio/transcriptions"

GPT_TRANSCRIBE = "gpt-transcribe"
WHISPER = "whisper-1"
TYPED = "typed"

#: Which transcript becomes the label: gpt-transcribe, else whisper-1. Slive's
#: typed text only ever votes — it is the very thing the label checks.
PREFERENCE = (GPT_TRANSCRIBE, WHISPER, TYPED)

#: The generic speaker line gpt-transcribe is seeded with; the user's own
#: Vocabulary context sentence (if any) follows it.
DEFAULT_CONTEXT = "Dictation to a computer: prompts, messages and notes, often technical."

#: Keyword list cap — the user's Custom words, not a dictionary.
MAX_KEYWORDS = 50

#: Retries per call after the first attempt (429 / 5xx / timeouts only).
MAX_RETRIES = 3
#: First backoff in seconds; doubles each retry. A server Retry-After is
#: honoured up to the cap so one call can't stall a clip for minutes.
BACKOFF_SECONDS = 1.0
RETRY_AFTER_CAP = 8.0


class LabelFatalError(FatalLabel):
    """The key itself is unusable (rejected, or out of quota) — every further
    clip would fail the same way, so the caller must stop the whole run
    (401 with ``fatal: kind``)."""


class _CallFailed(Exception):
    """One transcriber failed for this clip only; the others may still label it."""


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

def parse_hotwords(raw: str | list[str] | None) -> list[str]:
    """The user's Custom words, parsed the way the app does: comma and/or
    newline separated, whitespace collapsed, de-duplicated (first spelling
    wins). Items with ``<``/``>`` are dropped — they'd be read as markup."""
    if not raw:
        return []
    items = raw if isinstance(raw, list) else [raw]
    seen: set[str] = set()
    words: list[str] = []
    for item in items:
        for part in re.split(r"[,\r\n]", str(item)):
            word = " ".join(part.split())
            if not word or "<" in word or ">" in word:
                continue
            key = word.lower()
            if key in seen:
                continue
            seen.add(key)
            words.append(word)
    return words[:MAX_KEYWORDS]


def compose_prompt(context: str | None, base: str | None = None) -> str:
    """gpt-transcribe's prompt: the speaker line (the user's edit, else the
    default), then their context sentence (clipped — the endpoint's prompt
    budget is small)."""
    head = " ".join((base or "").split())[:400] or DEFAULT_CONTEXT
    ctx = " ".join((context or "").split())
    return f"{head} {ctx[:400]}" if ctx else head


_WORD_RE = re.compile(r"[a-z0-9']+")


def normalize_words(text: str) -> list[str]:
    """Words for comparison only: lowercase letters/digits/apostrophes, with
    hyphens as spaces ("sub-agent" = "sub agent")."""
    lowered = text.lower().replace("’", "'").replace("-", " ")
    return _WORD_RE.findall(lowered)


def word_distance(a: list[str], b: list[str]) -> int:
    """Levenshtein distance over words."""
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, word_a in enumerate(a, 1):
        current = [i]
        for j, word_b in enumerate(b, 1):
            current.append(min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + (word_a != word_b),
            ))
        previous = current
    return previous[-1]


def choose(candidates: dict[str, str]) -> tuple[str, str, float]:
    """Pick the label: ``(text, chosen, agreement)``.

    gpt-transcribe IS the label (whisper-1 when it failed — Slive's typed text
    never labels alone); the other candidates only vote on how far to trust
    it. ``agreement`` is 1 minus the label's mean length-normalised word
    distance to the others, 0 when there is nothing to compare against.

    Nov 1 2026 challenge (50 blind clips): picking the medoid let a worse
    whisper-1/typed version outvote gpt-transcribe on hard clips (5.6% vs
    4.6% WER) and brought back lowercase, unpunctuated labels; the vote is
    worth more as a trust score than as a picker.
    """
    names = [n for n in PREFERENCE if n in candidates]
    names += [n for n in candidates if n not in names]
    label_from = next((n for n in names if n != TYPED), None)
    if label_from is None:
        raise ValueError("No transcriber candidate to label from")
    words = {n: normalize_words(candidates[n]) for n in names}
    others = [o for o in names if o != label_from]
    if not others:
        return candidates[label_from].strip(), label_from, 0.0
    mean = sum(word_distance(words[label_from], words[o])
               / max(len(words[label_from]), len(words[o]), 1) for o in others) / len(others)
    return candidates[label_from].strip(), label_from, round(max(0.0, 1.0 - mean), 3)


#: A label with at least this many words no other voter heard needs a
#: listen and stays out of training. Nov 9 2026: gpt-transcribe, primed by
#: the Custom word "Bedrock", turned "and then fine tune and let's see" into
#: "in Bedrock, Hive, and NetC" at 81% agreement — over the 0.8 bar, so
#: only the words themselves gave it away. One lone word is usually a
#: Custom-word spelling the others can't know ("Claude" vs "cloud").
MIN_UNCONFIRMED_WORDS = 2


def unconfirmed_words(candidates: dict[str, str], chosen: str) -> list[str]:
    """Words of the label (``candidates[chosen]``) that none of the other
    candidates contain, in label order, each once — what only the label's
    transcriber heard. Empty when there is nothing to compare against."""
    others = [normalize_words(t) for n, t in candidates.items() if n != chosen]
    if chosen not in candidates or not others:
        return []
    heard = set().union(*others)
    seen: set[str] = set()
    solo: list[str] = []
    for word in normalize_words(candidates[chosen]):
        if word not in heard and word not in seen:
            seen.add(word)
            solo.append(word)
    return solo


# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

def _to_pcm16(audio: bytes) -> tuple[bytes, str]:
    """Re-encode a WAV as 16-bit PCM — what the bench measured, half the
    upload of Slive's Float32 capture (and long clips stay under the API's
    25 MB cap). Anything unreadable is sent as-is."""
    try:
        import soundfile as sf

        data, rate = sf.read(io.BytesIO(audio), dtype="float32")
        out = io.BytesIO()
        sf.write(out, data, rate, format="WAV", subtype="PCM_16")
        return out.getvalue(), "audio/wav"
    except Exception:  # noqa: BLE001 - fall back to the original bytes
        return audio, ""


def _is_quota_error(response: httpx.Response) -> bool:
    return "insufficient_quota" in response.text


def _retry_delay(attempt: int, response: httpx.Response | None) -> float:
    delay = BACKOFF_SECONDS * (2 ** attempt)
    if response is not None:
        try:
            delay = max(delay, float(response.headers.get("retry-after", "")))
        except ValueError:
            pass
    return min(delay, RETRY_AFTER_CAP)


async def _sleep(seconds: float) -> None:
    """Backoff sleep — a module hook so tests can skip the waiting."""
    await asyncio.sleep(seconds)


async def _transcribe(
    client: httpx.AsyncClient,
    api_key: str,
    name: str,
    fields: dict[str, str | list[str]],
    audio: bytes,
    filename: str,
    mime: str,
) -> str:
    """One /audio/transcriptions call with retries. Raises ``LabelFatalError``
    for a key problem, ``_CallFailed`` when this model can't label the clip."""
    last_error = ""
    for attempt in range(MAX_RETRIES + 1):
        response: httpx.Response | None = None
        try:
            response = await client.post(
                TRANSCRIPTIONS_URL,
                headers={"Authorization": f"Bearer {api_key}"},
                files={"file": (filename, audio, mime)},
                data=fields,
            )
        except (httpx.TimeoutException, httpx.TransportError) as exc:
            last_error = f"{type(exc).__name__}: {exc}"
        else:
            status = response.status_code
            if status in (401, 403):
                raise LabelFatalError(
                    "auth", f"OpenAI rejected the key ({status}) — check it in Models → OpenAI.")
            if not response.is_success and _is_quota_error(response):
                raise LabelFatalError(
                    "quota", "OpenAI says this key is out of quota — add credit, then resume.")
            if response.is_success:
                try:
                    text = str(response.json().get("text", "")).strip()
                except ValueError as exc:
                    raise _CallFailed(f"{name}: unreadable reply") from exc
                if not text:
                    raise _CallFailed(f"{name}: empty transcript")
                return text
            last_error = f"{name} {status}: {truncate(response.text, 200)}"
            if status != 429 and status < 500:
                raise _CallFailed(last_error)  # a bad request won't get better
        if attempt < MAX_RETRIES:
            await _sleep(_retry_delay(attempt, response))
    raise _CallFailed(last_error)


async def label(
    api_key: str,
    audio_b64: str,
    media_type: str = "audio/wav",
    typed: str = "",
    hotwords: str | list[str] | None = None,
    context: str | None = None,
    base_prompt: str | None = None,
) -> dict[str, Any]:
    """Label one clip by consensus. Returns ``{text, chosen, agreement,
    unconfirmed, candidates, prompt}``; raises ``LabelFatalError`` on a key problem and
    ``ValueError`` when neither hosted transcriber produced text."""
    if not api_key:
        raise LabelFatalError("auth", "No OpenAI key — add it in Models → OpenAI.")
    validate_audio_payload(audio_b64)
    audio = base64.b64decode(audio_b64)
    is_mp3 = "mp3" in media_type or "mpeg" in media_type
    mime = "audio/mpeg" if is_mp3 else "audio/wav"
    if not is_mp3:
        audio, converted = await asyncio.to_thread(_to_pcm16, audio)
        mime = converted or mime
    filename = "audio.mp3" if is_mp3 else "audio.wav"

    keywords = parse_hotwords(hotwords)
    prompt = compose_prompt(context, base_prompt)
    # A list value becomes one multipart field per item — the API reads
    # repeated ``keywords[]`` / ``languages[]`` fields (and 400s on bad ones).
    gpt_fields: dict[str, str | list[str]] = {
        "model": GPT_TRANSCRIBE, "response_format": "json",
        "languages[]": ["en"], "prompt": prompt,
    }
    if keywords:
        gpt_fields["keywords[]"] = keywords
    whisper_fields: dict[str, str | list[str]] = {
        "model": WHISPER, "language": "en", "response_format": "json"}

    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as client:
        results = await asyncio.gather(
            _transcribe(client, api_key, GPT_TRANSCRIBE, gpt_fields, audio, filename, mime),
            _transcribe(client, api_key, WHISPER, whisper_fields, audio, filename, mime),
            return_exceptions=True,
        )

    candidates: dict[str, str] = {}
    errors: list[str] = []
    for name, result in zip((GPT_TRANSCRIBE, WHISPER), results):
        if isinstance(result, LabelFatalError):
            raise result
        if isinstance(result, BaseException):
            if not isinstance(result, _CallFailed):
                logger.warning("consensus: %s crashed: %r", name, result)
            errors.append(str(result))
        else:
            candidates[name] = result
    if not candidates:
        raise ValueError("Both transcribers failed — " + "; ".join(errors))
    if errors:
        logger.info("consensus: degraded to %s (%s)", "+".join(candidates), "; ".join(errors))
    if typed.strip():
        candidates[TYPED] = typed.strip()

    text, chosen, agreement = choose(candidates)
    sent = prompt + (f"\n\nkeywords: {', '.join(keywords)}" if keywords else "")
    return {
        "text": text,
        "chosen": chosen,
        "agreement": agreement,
        "unconfirmed": unconfirmed_words(candidates, chosen),
        "candidates": candidates,
        "prompt": sent,
    }
