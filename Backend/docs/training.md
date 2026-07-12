# Slive Whisper training backend

The backend now provides the safe input boundary plus the first end-to-end
training job: validate at least 50 eligible captures, train a Balanced Whisper
LoRA adapter, merge it, convert it with WhisperKit tools, and atomically install
it for Slive's model selector.

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

## Start a training session

Training is deliberately unavailable below 50 eligible samples. Eligibility
uses `best-available`: corrected `finalText` first, then `llmTranscript`; raw
Whisper output is never a target.

Install the optional training dependency set:

```bash
uv sync --extra dev --extra training
```

Install/pin `whisperkittools` separately and expose its generator when it is not
on `PATH`:

```bash
export WHISPERKIT_GENERATE_MODEL=/path/to/whisperkit-generate-model
```

The Slive Training page calls:

```text
GET  /training/readiness
GET  /training/models
POST /training/start
GET  /training/jobs/<id>
```

The Training page now selects the source model and method explicitly. The backend
catalog mirrors every standard model variant in the pinned WhisperKit version:
`tiny`, `tiny.en`, `base`, `base.en`, `small`, `small.en`, `medium`, `medium.en`,
`large`, `large-v2`, and `large-v3`. Slive's optimized
`large-v3-v20240930_626MB` choice maps to the original
`openai/whisper-large-v3` trainable weights because the 626 MB artifact is a
Core ML distribution, not a separate Hugging Face training checkpoint.

Profiles are size-aware: small models use more adapter rank and shorter gradient
accumulation; large models use lower learning rates, rank 4, longer accumulation,
and more frequent KL checks. Samples are deterministically shuffled each epoch
to avoid capture-order bias.

The available SFT methods are:

- **LoRA**: supported locally on Apple MPS and on CUDA.
- **QLoRA**: NF4 4-bit base weights with double quantization and PEFT k-bit
  preparation. This requires a supported CUDA + bitsandbytes host. Apple MPS is
  not currently a supported bitsandbytes NF4 backend. QLoRA only quantizes the
  training load; post-training reloads the chosen base in full precision, merges
  the adapter, and then converts that merged checkpoint for WhisperKit.

The trainer then merges
the adapter into a standard Hugging Face checkpoint before conversion. The
portable installed result is named:

```text
balenced-ft-YYYYMMDD-HHMMSS
```

and stored under:

```text
~/Library/Application Support/Slive/Models/Custom/<model-name>/
```

Slive scans each custom model's `manifest.json`, validates its WhisperKit
components, and includes the exact `balenced-ft-*` name in both Dictation and
Continuous model selectors.

### Is 50 samples enough?

Fifty eligible samples plus five minutes of speech is the minimum safety gate,
not a quality guarantee. It is suitable for an experimental, narrow adaptation
when recordings cover the user's real distribution. A more credible first
personal model is 100–300 corrected clips and roughly 20–60 minutes, with varied
utterance lengths, vocabulary, pace, microphone distance, noise, and application
contexts. Repeated near-duplicates increase the count without adding equivalent
information. Low-data runs should keep the conservative size-specific profiles,
watch KL drift, and be evaluated against held-out general and personal speech
before replacing a stock model.

## Current boundaries

Not implemented yet:

- Audio resampling or copying into dataset snapshots.
- Train/validation/test splitting.
- Human verification UI or a `verified` schema field.
- Hugging Face `Dataset` conversion.
- Full-parameter fine-tuning.
- General replay data.
- Automatic evaluation/release gates beyond conversion structure validation.
- Resumable training after the backend or app is terminated.
- Pinned `whisperkittools` installation automation.
- Tuned GPU/MPS hardware profiles; device selection is currently CUDA, then MPS, then CPU.

Before production training, add immutable grouped splits, general replay, KL
retention, evaluation gates, and a detached/resumable worker process. The
current job is a first executable integration and should remain opt-in.
