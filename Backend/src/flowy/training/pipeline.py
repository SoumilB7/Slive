"""First executable Whisper LoRA -> merge -> WhisperKit conversion pipeline.

Heavy training dependencies are imported only after the 50-sample gate. Normal
dictation and assistant usage therefore remain lightweight.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

from flowy.training.store import LabelPolicy, TrainingStore, write_manifest

BALANCED_BASE_MODEL = "openai/whisper-large-v3"


@dataclass(frozen=True)
class PipelineConfig:
    model_name: str
    store_root: Path | None = None
    output_root: Path | None = None
    base_model: str = BALANCED_BASE_MODEL
    epochs: int = 3
    learning_rate: float = 1e-5
    lora_rank: int = 4
    batch_size: int = 1
    gradient_accumulation_steps: int = 8


Progress = Callable[..., None]


def default_output_root() -> Path:
    override = os.environ.get("SLIVE_TRAINING_OUTPUT_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Slive" / "training-runs"


def custom_models_root() -> Path:
    override = os.environ.get("SLIVE_CUSTOM_MODELS_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Slive" / "Models" / "Custom"


def run_pipeline(config: PipelineConfig, progress: Progress) -> Path:
    """Run all stages and return the atomically installed custom-model folder."""

    report = TrainingStore(config.store_root).inspect(label_policy=LabelPolicy.BEST_AVAILABLE)
    if report.eligible_count < 50:
        raise ValueError(f"Training requires 50 eligible samples; found {report.eligible_count}")

    output_root = config.output_root or default_output_root()
    run_dir = output_root / config.model_name
    run_dir.mkdir(parents=True, exist_ok=False)
    (run_dir / "config.json").write_text(
        json.dumps({**asdict(config), "store_root": str(config.store_root or "")}, indent=2, default=str),
        encoding="utf-8",
    )
    manifest_path = write_manifest(report, run_dir / "training-manifest.jsonl")
    progress(stage="dataset", message=f"Validated {report.eligible_count} samples", value=0.05,
             run_dir=str(run_dir))

    adapter_dir = run_dir / "adapter"
    merged_dir = run_dir / "merged-hf"
    converted_dir = run_dir / "whisperkit"

    _train_lora(config, report.eligible_samples, adapter_dir, progress)
    progress(stage="merging", message="Merging LoRA into Balanced Whisper", value=0.76)
    _merge_adapter(config, adapter_dir, merged_dir)
    progress(stage="converting", message="Converting merged model for WhisperKit", value=0.84)
    model_folder = _convert_whisperkit(merged_dir, converted_dir)
    progress(stage="installing", message="Installing fine-tuned model", value=0.96)
    installed = _install_model(config, model_folder, merged_dir, run_dir, manifest_path)
    return installed


def _training_imports():
    try:
        import torch
        from peft import LoraConfig, PeftModel, get_peft_model
        from transformers import WhisperForConditionalGeneration, WhisperProcessor
    except ImportError as exc:
        raise RuntimeError(
            "Whisper training dependencies are not installed. Run "
            "`uv sync --extra training` in Backend first."
        ) from exc
    return torch, LoraConfig, PeftModel, get_peft_model, WhisperForConditionalGeneration, WhisperProcessor


def _train_lora(config: PipelineConfig, samples, adapter_dir: Path, progress: Progress) -> None:
    torch, LoraConfig, _, get_peft_model, Model, Processor = _training_imports()
    device = _device(torch)
    processor = Processor.from_pretrained(config.base_model, language="en", task="transcribe")
    model = Model.from_pretrained(config.base_model)
    model.config.use_cache = False
    lora = LoraConfig(
        r=config.lora_rank,
        lora_alpha=config.lora_rank * 2,
        lora_dropout=0.05,
        bias="none",
        target_modules=["q_proj", "v_proj"],
    )
    model = get_peft_model(model, lora).to(device)
    model.train()
    optimizer = torch.optim.AdamW(
        (p for p in model.parameters() if p.requires_grad), lr=config.learning_rate
    )
    total_updates = max(1, config.epochs * len(samples))
    optimizer.zero_grad(set_to_none=True)
    update = 0
    kl_every = 4   # KL costs an extra (no-grad) forward — sample it, don't pay it every step
    for epoch in range(config.epochs):
        for index, sample in enumerate(samples):
            audio, rate = _load_audio(sample.audio.path)
            batch = processor(
                audio=audio,
                sampling_rate=rate,
                text=sample.reference_text,
                return_tensors="pt",
            )
            inputs = {key: value.to(device) for key, value in batch.items()}
            outputs = model(**inputs)
            loss = outputs.loss / config.gradient_accumulation_steps
            loss.backward()
            if (index + 1) % config.gradient_accumulation_steps == 0 or index + 1 == len(samples):
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                optimizer.zero_grad(set_to_none=True)
            update += 1
            # KL(fine-tuned ‖ base) per token: how far the adapted token
            # distribution has drifted from stock Balanced. The base forward
            # reuses the SAME weights with the LoRA adapter disabled — no
            # second model in memory.
            kl = None
            if update % kl_every == 0 or update == total_updates:
                with torch.no_grad(), model.disable_adapter():
                    base_logits = model(**inputs).logits
                log_p = torch.log_softmax(outputs.logits.detach(), dim=-1)
                log_q = torch.log_softmax(base_logits, dim=-1)
                kl = (log_p.exp() * (log_p - log_q)).sum(-1).mean().item()
            progress(
                stage="training",
                message=f"Epoch {epoch + 1}/{config.epochs} · sample {index + 1}/{len(samples)}",
                value=0.08 + 0.66 * (update / total_updates),
                total_updates=total_updates,
                metric={
                    "update": update,
                    "epoch": epoch + 1,
                    "loss": round(outputs.loss.item(), 4),
                    "kl": round(kl, 5) if kl is not None else None,
                },
            )
    adapter_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(adapter_dir)
    processor.save_pretrained(adapter_dir)
    del model


def _merge_adapter(config: PipelineConfig, adapter_dir: Path, merged_dir: Path) -> None:
    _, _, PeftModel, _, Model, Processor = _training_imports()
    base = Model.from_pretrained(config.base_model)
    merged = PeftModel.from_pretrained(base, adapter_dir).merge_and_unload()
    merged.save_pretrained(merged_dir, safe_serialization=True)
    Processor.from_pretrained(config.base_model).save_pretrained(merged_dir)


def _convert_whisperkit(merged_dir: Path, output_dir: Path) -> Path:
    executable = os.environ.get("WHISPERKIT_GENERATE_MODEL") or shutil.which(
        "whisperkit-generate-model"
    )
    if not executable:
        raise RuntimeError(
            "whisperkit-generate-model is not installed. Install the pinned "
            "WhisperKit tools and set WHISPERKIT_GENERATE_MODEL."
        )
    output_dir.mkdir(parents=True, exist_ok=True)
    command = [
        executable,
        "--model-version",
        str(merged_dir),
        "--output-dir",
        str(output_dir),
    ]
    completed = subprocess.run(command, text=True, capture_output=True, check=False)
    (output_dir / "conversion.log").write_text(
        completed.stdout + "\n" + completed.stderr, encoding="utf-8"
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"WhisperKit conversion failed ({completed.returncode}); see "
            f"{output_dir / 'conversion.log'}"
        )
    candidates = [
        path.parent
        for path in output_dir.rglob("AudioEncoder.mlmodelc")
        if (path.parent / "TextDecoder.mlmodelc").is_dir()
    ]
    if not candidates:
        raise RuntimeError("Conversion completed but no WhisperKit model folder was found")
    return candidates[0]


def _install_model(
    config: PipelineConfig,
    model_folder: Path,
    merged_dir: Path,
    run_dir: Path,
    training_manifest: Path,
) -> Path:
    root = custom_models_root()
    root.mkdir(parents=True, exist_ok=True)
    final = root / config.model_name
    staging = root / f".{config.model_name}.staging"
    if final.exists() or staging.exists():
        raise FileExistsError(f"Custom model already exists: {final}")
    staging.mkdir()
    shutil.copytree(model_folder, staging / "model")
    tokenizer = staging / "tokenizer"
    tokenizer.mkdir()
    for pattern in ("*token*", "vocab.json", "merges.txt", "preprocessor_config.json"):
        for source in merged_dir.glob(pattern):
            if source.is_file():
                shutil.copy2(source, tokenizer / source.name)
    manifest = {
        "id": config.model_name,
        "display_name": config.model_name,
        "base_model": config.base_model,
        "model_folder": "model",
        "tokenizer_folder": "tokenizer",
        "training_run": str(run_dir),
        "training_manifest": str(training_manifest),
        "created_at": config.model_name.removeprefix("balenced-ft-"),
    }
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    staging.replace(final)
    return final


def _device(torch):
    if torch.cuda.is_available():
        return torch.device("cuda")
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def _load_audio(path: str):
    import librosa

    return librosa.load(path, sr=16_000, mono=True)
