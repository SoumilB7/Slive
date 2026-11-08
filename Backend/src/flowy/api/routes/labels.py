"""Ground-truth labels for training clips: one audio-capable model, the
3-way consensus, and the consensus label's formatting step."""

from __future__ import annotations

from fastapi import APIRouter

from flowy.api.routes import ServicesDep
from flowy.api.schemas import LabelConsensusRequest, LabelFormatRequest, TranscribeLLMRequest
from flowy.errors import upstream_errors
from flowy.label_format import SYSTEM as FORMAT_PROMPT
from flowy.providers import TRANSCRIBE_PROMPT

router = APIRouter()


@router.get("/transcribe_llm/prompt")
async def transcribe_llm_prompt():
    """The shipped default transcription instruction — the editor's
    starting point and its Reset target."""
    return {"prompt": TRANSCRIBE_PROMPT}


@router.post("/transcribe_llm")
async def transcribe_llm(req: TranscribeLLMRequest, services: ServicesDep):
    with upstream_errors("LLM transcription failed"):
        text, prompt_used = await services.ai.transcribe_audio(req.provider, req.audio_input())
    # The exact instruction the model saw rides back — the UI shows it so
    # "what went in" is inspectable, vocabulary hint included.
    return {"text": text, "prompt": prompt_used}


@router.post("/label_consensus")
async def label_consensus(req: LabelConsensusRequest, services: ServicesDep):
    # A key problem (LabelFatalError) is a 401 with "fatal" — it fails every
    # clip the same way, so the app stops the whole run.
    with upstream_errors("Consensus label failed"):
        return await services.labeler.label(
            api_key=req.api_key,
            audio_b64=req.audio_b64,
            media_type=req.media_type,
            typed=req.typed,
            hotwords=req.hotwords,
            context=req.context,
            base_prompt=req.base_prompt,
        )


@router.get("/label_format/prompt")
async def label_format_prompt():
    """The formatter's system instruction, for the app's read-only view."""
    return {"prompt": FORMAT_PROMPT}


@router.post("/label_format")
async def label_format(req: LabelFormatRequest, services: ServicesDep):
    # Same error contract as /label_consensus: a key problem is a 401 with
    # "fatal" (stop the run), a failed call for this clip a 400.
    with upstream_errors("Label format failed"):
        result = await services.formatter.format_label(
            api_key=req.api_key,
            label=req.label,
            hotwords=req.hotwords,
            agreement=req.agreement,
            word_count=req.word_count,
        )
    return {key: result[key] for key in ("formatted", "status", "model")}
