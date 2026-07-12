# Slive Whisper training backend — v1 foundation

This first version does not train a model. It establishes the safe input boundary between the Swift app's captured data and the future Whisper trainer.

## Source store

By default, `flowy-train` reads:

```text
~/Library/Application Support/Slive/training/
├── samples.jsonl
└── audio/<sample-id>.wav
```

Override it for development or testing:

```bash
export SLIVE_TRAINING_DIR=/path/to/training
```

or pass `--store` explicitly.

Inspection is read-only. Building a manifest writes only to the path supplied with `--output`; it never edits Slive's source store.

## Label policies

The stored fields have different trust levels:

| Policy | Accepted target | Fallback |
|---|---|---|
| `verified` | Non-empty `finalText` | None |
| `llm` | Non-empty `llmTranscript` | None |
| `best-available` | `finalText` | `llmTranscript` |

The raw `transcript` is Slive/Whisper's own prediction. It is preserved in manifests for error analysis but is never accepted as a supervised target.

`verified` is the default and safest policy. The current Swift store does not yet have an explicit human-verification boolean, so v1 treats a non-empty corrected `finalText` as the strongest available label. The future review UI should add explicit provenance and verification.

## Inspect current data

From `Backend/`:

```bash
.venv/bin/flowy-train inspect
.venv/bin/flowy-train inspect --show-rejections
.venv/bin/flowy-train inspect --label-policy best-available --json
```

The command checks:

- JSONL schema and malformed rows.
- Duplicate sample IDs.
- Relative audio paths and path traversal.
- Missing audio files.
- Decodable audio metadata.
- Duration boundaries (default 0.5–30 seconds).
- Duplicate audio content by SHA-256.
- Label eligibility under the selected policy.

Exit status is `0` when at least one sample is eligible and `1` when none are eligible. A missing store is reported rather than created.

## Build a deterministic training manifest

```bash
.venv/bin/flowy-train build-manifest \
  --label-policy best-available \
  --output outputs/training/manifest.jsonl
```

Each eligible row contains:

- Absolute validated audio path.
- Audio SHA-256, size, frames, sample rate, channels, duration, format, and subtype.
- Selected reference text and provenance.
- Original Slive prediction.
- LLM model provenance where present.
- Capture timestamp and source app bundle identifier.

The writer uses a temporary file and atomic rename. It refuses to create an empty manifest unless `--allow-empty` is explicitly supplied.

## Deliberate v1 boundaries

Not implemented yet:

- Audio resampling or copying into dataset snapshots.
- Train/validation/test splitting.
- Human verification UI or a `verified` schema field.
- Hugging Face `Dataset` conversion.
- Whisper processor/tokenization.
- LoRA or full fine-tuning.
- General replay data.
- KL-divergence retention.
- Checkpointing, evaluation, merge, or WhisperKit export.
- GPU/MPS/ANE hardware orchestration.

The next backend layer should create immutable dataset snapshots and grouped splits from this validated manifest before importing any model-training stack.
