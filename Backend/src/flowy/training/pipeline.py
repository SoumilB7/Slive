"""First executable Whisper LoRA -> merge -> WhisperKit conversion pipeline.

Heavy training dependencies are imported only after the 50-sample gate. Normal
dictation and assistant usage therefore remain lightweight.
"""

from __future__ import annotations

import json
import importlib.util
import math
import os
import random
import shutil
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

import psutil

from flowy.training.models import DEFAULT_TRAINING_MODEL, get_training_model
from flowy.training.store import LabelPolicy, TrainingStore, write_manifest


@dataclass(frozen=True)
class PipelineConfig:
    model_name: str
    store_root: Path | None = None
    output_root: Path | None = None
    source_model: str = DEFAULT_TRAINING_MODEL
    base_model: str = ""
    method: str = "hybrid"
    max_ram_gb: float = 12.0
    epochs: int = 3
    learning_rate: float = 1e-4
    lora_rank: int = 16
    kl_weight: float = 0.3
    # QLoRA (CUDA host) only — the local methods batch by METHOD_MICRO_BATCH.
    gradient_accumulation_steps: int = 8
    kl_every: int = 4

    @classmethod
    def for_model(cls, *, model_name: str, source_model: str, **kwargs) -> "PipelineConfig":
        profile = get_training_model(source_model)
        return cls(
            model_name=model_name,
            source_model=profile.id,
            base_model=profile.hf_model,
            learning_rate=profile.learning_rate,
            lora_rank=profile.lora_rank,
            kl_weight=profile.kl_weight,
            **kwargs,
        )


#: Local training methods (Apple silicon / CPU / CUDA alike). Measured Oct 12
#: on an M4 Air 16GB with turbo + 394 clips: full-forward LoRA ran 100 s/clip
#: (~11 h per epoch) and a torchao NF4 "QLoRA" 161 s/clip — the frozen 32-layer
#: encoder dominates, so it runs ONCE per clip and its output is cached:
#:   hybrid  — cache the hidden state entering the top quarter of the encoder;
#:             LoRA on those layers (accent) + every decoder linear
#:             (vocabulary). 3.1 s/clip/epoch, 6.2 GB Metal peak.
#:   decoder — cache the encoder output; LoRA on the decoder only. 0.33
#:             s/clip/epoch, 4.4 GB — quick, but it lowercased generic
#:             sentences where hybrid did not.
#: Caching costs ~2.7 s/clip once (turbo).
LOCAL_METHODS = ("hybrid", "decoder")
TRAINING_METHODS = (*LOCAL_METHODS, "qlora")
METHOD_MICRO_BATCH = {"hybrid": 2, "decoder": 8}
EFFECTIVE_BATCH = 8


def encoder_cut(method: str, encoder_layers: int) -> int:
    """Index of the first trainable encoder layer (== encoder_layers: frozen)."""
    if method == "decoder":
        return encoder_layers
    return encoder_layers - max(1, encoder_layers // 4)


def lora_target_pattern(cut: int, encoder_layers: int) -> str:
    """PEFT full-match regex: every decoder attention/MLP linear, plus the
    encoder layers from `cut` up."""
    decoder = (r".*decoder\.layers\.\d+\."
               r"((self_attn|encoder_attn)\.(q_proj|k_proj|v_proj|out_proj)|fc1|fc2)")
    if cut >= encoder_layers:
        return decoder
    layers = "|".join(str(i) for i in range(cut, encoder_layers))
    encoder = (rf".*encoder\.layers\.({layers})\."
               r"(self_attn\.(q_proj|k_proj|v_proj|out_proj)|fc1|fc2)")
    return f"({decoder})|({encoder})"


def lr_factor(update: int, total: int) -> float:
    """Linear warm-up over the first 10% of updates, then cosine to zero."""
    warm = max(1, total // 10)
    if update < warm:
        return (update + 1) / warm
    progress = min(1.0, (update - warm) / max(1, total - warm))
    return 0.5 * (1 + math.cos(math.pi * progress))


def pad_label_batch(
    sequences: list[list[int]], pad_id: int, forced: int
) -> tuple[list[list[int]], list[list[int]]]:
    """Teacher-forcing inputs + labels from full token sequences
    (SOT, prefix…, text…, EOT). The first `forced` labels are the prefix tokens
    WhisperKit forces at inference (language/task/notimestamps) — masked, so
    the loss is spent on the words. Padding is masked with -100."""
    width = max(len(seq) for seq in sequences) - 1
    inputs, labels = [], []
    for seq in sequences:
        n = len(seq) - 1
        inputs.append(seq[:-1] + [pad_id] * (width - n))
        target = [-100] * min(forced, n) + seq[1 + forced:]
        labels.append(target + [-100] * (width - len(target)))
    return inputs, labels


def teacher_forcing_pair(sequence: list[int], forced: int) -> tuple[list[int], list[int]]:
    """One sample's (decoder_input_ids, labels) in `pad_label_batch`'s
    convention. Passing explicit decoder inputs stops Transformers from
    right-shifting labels that already begin with SOT (a doubled SOT), and the
    forced prefix is masked as in the cached trainer."""
    inputs, labels = pad_label_batch([sequence], pad_id=0, forced=forced)
    return inputs[0], labels[0]


def configure_prefix_tokens(tokenizer, model) -> int:
    """Set the English/transcribe/no-timestamps prefix WhisperKit forces at
    inference and return how many prefix tokens follow SOT (masked in labels)."""
    if getattr(model.generation_config, "is_multilingual", True):
        tokenizer.set_prefix_tokens(language="en", task="transcribe", predict_timestamps=False)
    else:
        tokenizer.set_prefix_tokens(predict_timestamps=False)
    return len(tokenizer.prefix_tokens) - 1


def require_finite_loss(where: str, **values: float) -> None:
    """Abort on NaN/inf instead of training garbage for the rest of the run."""
    bad = {name: value for name, value in values.items() if not math.isfinite(value)}
    if bad:
        detail = ", ".join(f"{name}={value}" for name, value in bad.items())
        raise RuntimeError(
            f"Training diverged at {where}: {detail}. Nothing was installed — "
            f"try a lower learning rate, the Decoder method, or remove odd samples."
        )


def whisperkit_converter() -> str:
    """Resolve the WhisperKit converter (WHISPERKIT_GENERATE_MODEL, else PATH)
    or raise ValueError — checked BEFORE training so a missing tool doesn't
    surface only after tens of minutes of work."""
    configured = os.environ.get("WHISPERKIT_GENERATE_MODEL")
    if configured:
        executable = shutil.which(configured)
        if not executable:
            raise ValueError(
                f"WHISPERKIT_GENERATE_MODEL points to “{configured}”, which is not "
                f"an executable file. Fix the path before training."
            )
        return executable
    executable = shutil.which("whisperkit-generate-model")
    if not executable:
        raise ValueError(
            "whisperkit-generate-model is not installed, so a trained model "
            "could not be converted for WhisperKit. Install the pinned "
            "WhisperKit tools (or set WHISPERKIT_GENERATE_MODEL) before training."
        )
    return executable


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

    converter = whisperkit_converter()
    memory = MemoryGuard(config.max_ram_gb)
    memory.check("dataset preparation")
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

    if config.method == "qlora":
        _train_lora(config, report.eligible_samples, adapter_dir, progress, memory)
    else:
        cache_dir = run_dir / "encoder-cache"
        try:
            _train_cached(config, report.eligible_samples, adapter_dir, cache_dir,
                          progress, memory)
        finally:
            # ~3.8 MB per clip — never left behind by a failed or aborted run.
            shutil.rmtree(cache_dir, ignore_errors=True)
    memory.check("adapter merge")
    progress(stage="merging", message="Merging LoRA into Balanced Whisper", value=0.76)
    _merge_adapter(config, adapter_dir, merged_dir)
    memory.check("WhisperKit conversion")
    progress(stage="converting", message="Converting merged model for WhisperKit", value=0.84)
    model_folder = _convert_whisperkit(merged_dir, converted_dir, converter)
    progress(stage="installing", message="Installing fine-tuned model", value=0.96)
    installed = _install_model(config, model_folder, merged_dir, run_dir, manifest_path)
    return installed


def _training_imports():
    try:
        import torch
        from peft import (
            LoraConfig,
            PeftModel,
            get_peft_model,
            prepare_model_for_kbit_training,
        )
        from transformers import WhisperForConditionalGeneration, WhisperProcessor
    except ImportError as exc:
        raise RuntimeError(
            "Whisper training dependencies are not installed. Run "
            "`uv sync --extra training` in Backend first."
        ) from exc
    return (
        torch,
        LoraConfig,
        PeftModel,
        get_peft_model,
        prepare_model_for_kbit_training,
        WhisperForConditionalGeneration,
        WhisperProcessor,
    )


class MemoryGuard:
    """Cooperative ceiling on process RSS + Metal allocations for the
    in-process trainer. On Apple silicon the model and activations live in
    Metal buffers that RSS doesn't count (measured: 0.3 GB RSS at a 6.2 GB
    Metal peak), so the trainer plugs in `extra_bytes`."""

    def __init__(self, limit_gb: float):
        self.limit_gb = limit_gb
        self.limit_bytes = int(limit_gb * 1024**3)
        self.process = psutil.Process()
        self.extra_bytes: Callable[[], int] = lambda: 0

    def used_gb(self) -> float:
        return (self.process.memory_info().rss + self.extra_bytes()) / 1024**3

    def check(self, stage: str) -> None:
        used = self.process.memory_info().rss + self.extra_bytes()
        if used > self.limit_bytes:
            raise RuntimeError(
                f"SFT stopped during {stage}: RAM use reached {used / 1024**3:.2f} GB, "
                f"above the {self.limit_gb:g} GB limit. Choose a smaller model, the "
                "Decoder method, or raise the limit."
            )


def _train_lora(
    config: PipelineConfig, samples, adapter_dir: Path, progress: Progress, memory: MemoryGuard
) -> None:
    torch, LoraConfig, _, get_peft_model, prepare_kbit, Model, Processor = _training_imports()
    device = _device(torch)
    processor = Processor.from_pretrained(config.base_model)
    if config.method == "qlora":
        if device.type != "cuda":
            raise RuntimeError(
                "QLoRA needs a supported 4-bit backend. Apple MPS is not supported "
                "by bitsandbytes NF4; choose LoRA on this Mac or run QLoRA on CUDA."
            )
        if importlib.util.find_spec("bitsandbytes") is None:
            raise RuntimeError("QLoRA requires bitsandbytes on the CUDA host.")
        try:
            from transformers import BitsAndBytesConfig

            quantization = BitsAndBytesConfig(
                load_in_4bit=True,
                bnb_4bit_quant_type="nf4",
                bnb_4bit_use_double_quant=True,
                bnb_4bit_compute_dtype=torch.bfloat16,
            )
            model = Model.from_pretrained(
                config.base_model,
                quantization_config=quantization,
                device_map={"": device.index or 0},
            )
        except (ImportError, OSError) as exc:
            raise RuntimeError("QLoRA requires bitsandbytes on the CUDA host.") from exc
        model = prepare_kbit(model)
    else:
        model = Model.from_pretrained(config.base_model).to(device)
    memory.check("model loading")
    model.config.use_cache = False
    forced = configure_prefix_tokens(processor.tokenizer, model)
    lora = LoraConfig(
        r=config.lora_rank,
        lora_alpha=config.lora_rank * 2,
        lora_dropout=0.05,
        bias="none",
        target_modules=["q_proj", "v_proj"],
    )
    model = get_peft_model(model, lora)
    model.train()
    optimizer = torch.optim.AdamW(
        (p for p in model.parameters() if p.requires_grad), lr=config.learning_rate
    )
    total_updates = max(1, config.epochs * len(samples))
    optimizer.zero_grad(set_to_none=True)
    update = 0
    kl_every = config.kl_every
    for epoch in range(config.epochs):
        epoch_samples = list(samples)
        random.Random(17 + epoch).shuffle(epoch_samples)
        for index, sample in enumerate(epoch_samples):
            memory.check(f"epoch {epoch + 1} sample {index + 1}")
            audio, rate = _load_audio(sample.audio.path)
            features = processor.feature_extractor(
                audio, sampling_rate=rate, return_tensors="pt"
            ).input_features
            decoder_ids, labels = teacher_forcing_pair(
                processor.tokenizer(sample.reference_text).input_ids, forced)
            inputs = {
                "input_features": features.to(device),
                "decoder_input_ids": torch.tensor([decoder_ids], device=device),
                "labels": torch.tensor([labels], device=device),
            }
            outputs = model(**inputs)
            memory.check(f"epoch {epoch + 1} forward pass")
            loss_value = outputs.loss.item()
            require_finite_loss(f"epoch {epoch + 1} sample {index + 1}", loss=loss_value)
            loss = outputs.loss / config.gradient_accumulation_steps
            loss.backward()
            if ((index + 1) % config.gradient_accumulation_steps == 0
                    or index + 1 == len(epoch_samples)):
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
                require_finite_loss(f"epoch {epoch + 1} sample {index + 1}", kl=kl)
            progress(
                stage="training",
                message=f"Epoch {epoch + 1}/{config.epochs} · sample {index + 1}/{len(samples)}",
                value=0.08 + 0.66 * (update / total_updates),
                total_updates=total_updates,
                metric={
                    "update": update,
                    "epoch": epoch + 1,
                    "loss": round(loss_value, 4),
                    "kl": round(kl, 5) if kl is not None else None,
                },
            )
    adapter_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(adapter_dir)
    processor.save_pretrained(adapter_dir)
    del model


def _train_cached(
    config: PipelineConfig,
    samples,
    adapter_dir: Path,
    cache_dir: Path,
    progress: Progress,
    memory: MemoryGuard,
) -> None:
    """The local trainer (hybrid / decoder): encode every clip once through
    the frozen encoder, then train LoRA on top of the cache with
    CE + kl_weight x KL(base || fine-tuned) against the same weights with the
    adapter disabled (no second model in memory)."""
    import numpy as np

    torch, LoraConfig, _, get_peft_model, _, Model, Processor = _training_imports()
    device = _device(torch)
    if device.type == "mps":
        memory.extra_bytes = torch.mps.driver_allocated_memory
    processor = Processor.from_pretrained(config.base_model)
    model = Model.from_pretrained(config.base_model, dtype=torch.float32).to(device)
    model.config.use_cache = False
    model.eval()
    memory.check("model loading")

    tokenizer = processor.tokenizer
    forced = configure_prefix_tokens(tokenizer, model)
    sequences = [tokenizer(sample.reference_text).input_ids for sample in samples]

    # 1. Cache — the frozen encoder runs once per clip.
    encoder_layers = model.config.encoder_layers
    cut = encoder_cut(config.method, encoder_layers)
    encoder = model.model.encoder
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / "encoder.npy"
    cache = np.lib.format.open_memmap(
        cache_path, mode="w+", dtype=np.float16,
        shape=(len(samples), model.config.max_source_positions, model.config.d_model),
    )
    with torch.no_grad():
        for start in range(0, len(samples), 4):
            chunk = samples[start:start + 4]
            audio = [_load_audio(sample.audio.path)[0][: 30 * 16_000] for sample in chunk]
            features = processor.feature_extractor(
                audio, sampling_rate=16_000, return_tensors="pt"
            ).input_features.to(device)
            out = encoder(features, output_hidden_states=cut < encoder_layers)
            hidden = out.hidden_states[cut] if cut < encoder_layers else out.last_hidden_state
            # Whole-batch .cpu() first: on MPS a one-shot device+dtype cast of
            # a batch SLICE returned NaN for every row but the first.
            cache[start:start + len(chunk)] = hidden.cpu().to(torch.float16).numpy()
            memory.check("encoding clips")
            done = start + len(chunk)
            progress(stage="training", message=f"Encoding clips {done}/{len(samples)}",
                     value=0.06 + 0.12 * done / len(samples))
    cache.flush()

    # 2. LoRA on top of the cache.
    model = get_peft_model(model, LoraConfig(
        r=config.lora_rank,
        lora_alpha=config.lora_rank,
        use_rslora=True,
        lora_dropout=0.05,
        bias="none",
        target_modules=lora_target_pattern(cut, encoder_layers),
    ))
    core = model.base_model.model
    params = [p for p in model.parameters() if p.requires_grad]
    optimizer = torch.optim.AdamW(params, lr=config.learning_rate, weight_decay=0.0)
    micro = METHOD_MICRO_BATCH[config.method]
    accumulation = max(1, EFFECTIVE_BATCH // micro)
    steps_per_epoch = math.ceil(len(samples) / micro)
    updates_per_epoch = math.ceil(steps_per_epoch / accumulation)
    total_updates = max(1, config.epochs * updates_per_epoch)
    scheduler = torch.optim.lr_scheduler.LambdaLR(
        optimizer, lambda update: lr_factor(update, total_updates))

    def top_encoder(hidden):
        for layer in core.model.encoder.layers[cut:]:
            if torch.is_grad_enabled():
                # 1500-frame activations through the top layers OOM'd at
                # batch 4 without checkpointing.
                hidden = torch.utils.checkpoint.checkpoint(layer, hidden, None, use_reentrant=False)
            else:
                hidden = layer(hidden, None)
            hidden = hidden[0] if isinstance(hidden, tuple) else hidden
        return core.model.encoder.layer_norm(hidden)

    def logits(encoded, inputs, mask):
        hidden = core.model.decoder(input_ids=inputs, encoder_hidden_states=encoded).last_hidden_state
        # Vocab projection on real label rows only: the 51,866-way proj_out
        # over padding drove Metal to 11 GB at batch 8.
        return core.proj_out(hidden[mask])

    model.train()
    update = 0
    for epoch in range(config.epochs):
        order = list(range(len(samples)))
        random.Random(17 + epoch).shuffle(order)
        batches = [order[i:i + micro] for i in range(0, len(order), micro)]
        window_loss, window_kl = [], []
        for index, batch in enumerate(batches):
            memory.check(f"epoch {epoch + 1} step {index + 1}")
            rows = sorted(batch)
            cached = torch.from_numpy(np.ascontiguousarray(cache[rows])).to(device, torch.float32)
            inputs, labels = pad_label_batch(
                [sequences[i] for i in rows], tokenizer.eos_token_id, forced)
            inputs = torch.tensor(inputs, device=device)
            labels = torch.tensor(labels, device=device)
            mask = labels != -100
            encoded = top_encoder(cached) if cut < encoder_layers else cached
            tuned = logits(encoded, inputs, mask)
            with torch.no_grad(), model.disable_adapter():
                base_encoded = top_encoder(cached) if cut < encoder_layers else cached
                base = logits(base_encoded, inputs, mask)
            ce = torch.nn.functional.cross_entropy(tuned, labels[mask])
            log_p = torch.log_softmax(tuned, dim=-1)
            log_q = torch.log_softmax(base, dim=-1)
            kl = (log_q.exp() * (log_q - log_p)).sum(-1).mean()
            ce_value, kl_value = ce.item(), kl.item()
            require_finite_loss(f"epoch {epoch + 1} step {index + 1}", loss=ce_value, kl=kl_value)
            loss = ce + config.kl_weight * kl
            (loss / accumulation).backward()
            window_loss.append(ce_value)
            window_kl.append(kl_value)
            del tuned, base, log_p, log_q, loss
            if device.type == "mps":
                torch.mps.empty_cache()
            if (index + 1) % accumulation == 0 or index + 1 == len(batches):
                torch.nn.utils.clip_grad_norm_(params, 1.0)
                optimizer.step()
                optimizer.zero_grad(set_to_none=True)
                scheduler.step()
                update += 1
                progress(
                    stage="training",
                    message=f"Epoch {epoch + 1}/{config.epochs} · step {index + 1}/{len(batches)}",
                    value=0.18 + 0.56 * (update / total_updates),
                    total_updates=total_updates,
                    metric={
                        "update": update,
                        "epoch": epoch + 1,
                        "loss": round(sum(window_loss) / len(window_loss), 4),
                        "kl": round(sum(window_kl) / len(window_kl), 5),
                    },
                )
                window_loss, window_kl = [], []
    adapter_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(adapter_dir)
    processor.save_pretrained(adapter_dir)
    del cache, model


def _merge_adapter(config: PipelineConfig, adapter_dir: Path, merged_dir: Path) -> None:
    _, _, PeftModel, _, _, Model, Processor = _training_imports()
    base = Model.from_pretrained(config.base_model)
    merged = PeftModel.from_pretrained(base, adapter_dir).merge_and_unload()
    merged.save_pretrained(merged_dir, safe_serialization=True)
    Processor.from_pretrained(config.base_model).save_pretrained(merged_dir)


def _convert_whisperkit(merged_dir: Path, output_dir: Path, executable: str) -> Path:
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
        "source_model": config.source_model,
        "training_method": config.method,
        "max_ram_gb": config.max_ram_gb,
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
