"""WhisperKit-compatible source models and size-aware training profiles."""

from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class TrainingModel:
    id: str
    label: str
    hf_model: str
    family: str
    multilingual: bool
    learning_rate: float
    lora_rank: int
    gradient_accumulation_steps: int
    kl_every: int
    lora_ram_gb: float
    qlora_ram_gb: float
    detail: str

    def public_dict(self) -> dict:
        return asdict(self)


def _model(
    variant: str,
    label: str,
    family: str,
    *,
    english_only: bool = False,
    detail: str,
) -> TrainingModel:
    # Smaller checkpoints can use a little more adapter capacity and update
    # more often. Large checkpoints use a lower LR/rank and accumulate longer:
    # less trainable state, lower peak pressure, and safer movement on a small
    # personal corpus.
    profiles = {
        # lr, rank, accumulation, KL cadence, LoRA host/unified RAM, QLoRA host RAM
        "tiny": (2e-5, 8, 4, 8, 2.0, 2.0),
        "base": (1.5e-5, 8, 4, 8, 3.0, 2.0),
        "small": (1e-5, 4, 8, 6, 5.0, 3.0),
        "medium": (7.5e-6, 4, 12, 4, 9.0, 4.0),
        "large": (5e-6, 4, 16, 4, 14.0, 6.0),
    }
    learning_rate, rank, accumulation, kl_every, lora_ram, qlora_ram = profiles[family]
    suffix = ".en" if english_only else ""
    hf_variant = f"{variant}{suffix}"
    return TrainingModel(
        id=hf_variant,
        label=label,
        hf_model=f"openai/whisper-{hf_variant}",
        family=family,
        multilingual=not english_only,
        learning_rate=learning_rate,
        lora_rank=rank,
        gradient_accumulation_steps=accumulation,
        kl_every=kl_every,
        lora_ram_gb=lora_ram,
        qlora_ram_gb=qlora_ram,
        detail=detail,
    )


# Mirrors ModelVariant.allCases in the pinned WhisperKit checkout. Keep the
# optimized model currently exposed by Slive as an explicit alias below.
_STANDARD = (
    _model("tiny", "Tiny", "tiny", detail="Smallest multilingual model; fastest training"),
    _model("tiny", "Tiny English", "tiny", english_only=True, detail="Fastest English-only model"),
    _model("base", "Base", "base", detail="Light multilingual model"),
    _model("base", "Base English", "base", english_only=True, detail="Efficient English-only baseline"),
    _model("small", "Small", "small", detail="Mid-size multilingual model"),
    _model("small", "Small English", "small", english_only=True, detail="Mid-size English-only model"),
    _model("medium", "Medium", "medium", detail="High accuracy; heavier Mac training"),
    _model("medium", "Medium English", "medium", english_only=True, detail="High-accuracy English model"),
    _model("large", "Large", "large", detail="Original multilingual large model"),
    _model("large-v2", "Large v2", "large", detail="Second-generation multilingual large model"),
    _model("large-v3", "Large v3", "large", detail="Most accurate supported stock model"),
)

_large_v3 = _STANDARD[-1]
_OPTIMIZED_BALANCED = TrainingModel(
    **{
        **asdict(_large_v3),
        "id": "large-v3-v20240930_626MB",
        "label": "Balanced (626 MB source)",
        "detail": (
            "Trains from openai/whisper-large-v3; the stock 626 MB package is "
            "an optimized Core ML distribution, not separate trainable weights"
        ),
    }
)

TRAINING_MODELS = (_OPTIMIZED_BALANCED, *_STANDARD)
DEFAULT_TRAINING_MODEL = _OPTIMIZED_BALANCED.id
_BY_ID = {model.id: model for model in TRAINING_MODELS}


def get_training_model(model_id: str) -> TrainingModel:
    try:
        return _BY_ID[model_id]
    except KeyError as exc:
        raise ValueError(f"Unsupported WhisperKit training model: {model_id}") from exc


def training_models_payload() -> list[dict]:
    return [model.public_dict() for model in TRAINING_MODELS]
