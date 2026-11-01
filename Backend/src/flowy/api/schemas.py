"""Request bodies. Field names and defaults are the Swift app's wire format."""

from __future__ import annotations

from pydantic import BaseModel, Field, field_validator

from flowy.providers.base import AudioInput, ChatInput


def _clean_api_key(value: str) -> str:
    """Strip surrounding whitespace/newlines from an API key and reject any that
    still contains control characters.

    A key pasted with a trailing newline (or otherwise malformed) would reach the
    HTTP layer as an illegal ``Authorization`` header value and raise a cryptic
    httpx error mid-request. Sanitising at the request boundary turns that into a
    clean, explainable 4xx instead.
    """
    cleaned = value.strip()
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in cleaned):
        raise ValueError("API key contains invalid (control) characters")
    return cleaned


class ImageItem(BaseModel):
    media_type: str
    data: str


class HistoryItem(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    """``/assistant`` and ``/assistant/stream``."""

    text: str
    provider: str
    model: str
    api_key: str
    base_url: str | None = None
    system_prompt: str | None = None
    max_tokens: int = 1024
    images: list[ImageItem] | None = None
    history: list[HistoryItem] | None = None
    # Local-provider knobs (ignored for cloud providers): int8 weight-only
    # quantization and the resident-memory ceiling in GB.
    local_quantized: bool = True
    local_mem_gb: float | None = None

    _clean_key = field_validator("api_key")(_clean_api_key)

    def chat_input(self) -> ChatInput:
        return ChatInput(
            text=self.text,
            model=self.model,
            api_key=self.api_key,
            base_url=self.base_url,
            system_prompt=self.system_prompt,
            max_tokens=self.max_tokens,
            images=[img.model_dump() for img in self.images] if self.images else None,
            history=[h.model_dump() for h in self.history] if self.history else None,
            local_quantized=self.local_quantized,
            local_mem_gb=self.local_mem_gb,
        )


class TranscribeLLMRequest(BaseModel):
    """Ground-truth transcription of a captured dictation via an audio-capable
    multimodal model (Gemini / OpenAI audio). Same per-request key model as
    /assistant — nothing stored server-side."""

    provider: str
    model: str
    api_key: str
    audio_b64: str
    media_type: str = "audio/wav"
    base_url: str | None = None
    local_quantized: bool = True
    local_mem_gb: float | None = None
    #: The user's Vocabulary (hotwords + context) — appended to the
    #: transcription prompt so the judge spells the speaker's names/terms
    #: the way the main dictation model was told to.
    vocab_hint: str | None = None
    #: The user's edited base instruction (empty/None = the shipped default).
    #: The vocabulary tail is ALWAYS appended live, whatever the base.
    prompt_override: str | None = None

    _clean_key = field_validator("api_key")(_clean_api_key)

    def audio_input(self) -> AudioInput:
        return AudioInput(
            model=self.model,
            api_key=self.api_key,
            audio_b64=self.audio_b64,
            media_type=self.media_type,
            base_url=self.base_url,
            local_quantized=self.local_quantized,
            local_mem_gb=self.local_mem_gb,
            vocab_hint=self.vocab_hint,
            prompt_override=self.prompt_override,
        )


class LabelConsensusRequest(BaseModel):
    """One clip for the 3-way consensus labeler (gpt-transcribe + whisper-1 +
    Slive's own transcript). OpenAI key per request, nothing stored."""

    api_key: str
    audio_b64: str
    media_type: str = "audio/wav"
    #: What Slive typed for this clip — the third vote.
    typed: str = ""
    #: The user's Custom words: a list, or the raw comma/newline string.
    hotwords: list[str] | str = ""
    #: The user's Vocabulary context sentence (may be empty).
    context: str = ""
    #: The user's edit of the speaker line; empty = the default.
    base_prompt: str = ""

    _clean_key = field_validator("api_key")(_clean_api_key)


class ModelsRequest(BaseModel):
    provider: str
    api_key: str
    base_url: str | None = None

    _clean_key = field_validator("api_key")(_clean_api_key)


class LocalDownloadRequest(BaseModel):
    repo_id: str
    token: str | None = None


class LocalDeleteRequest(BaseModel):
    repo_id: str


class TrainingStartRequest(BaseModel):
    source_model: str
    method: str = "hybrid"
    #: Optional user-chosen name for the finished model (sanitized server-side;
    #: empty → the timestamped default).
    name: str | None = None
    max_ram_gb: float = Field(default=12.0, ge=2, le=128)
