# Flowy

Local speech-to-translated-text experiments using `google/gemma-4-E2B-it`.

The first milestone intentionally handles one audio clip of at most 30 seconds. It establishes
a correctness and latency baseline before adding long-audio chunking, microphone streaming,
quantization, or an application server.

## Machine baseline

- Apple M4 MacBook Air, 16 GB unified memory
- Python 3.12
- PyTorch MPS acceleration
- Gemma 4 E2B instruction-tuned model (approximately 10.2 GB BF16 weights)

The model is expected to fit tightly. Close memory-heavy applications before the first run.
macOS may use swap, and the first load can be substantially slower than later inference.

## Prerequisites

1. Install `ffmpeg` for reliable decoding and conversion of common audio formats:

   ```bash
   brew install ffmpeg
   ```

2. Create the Python environment:

   ```bash
   uv sync --extra dev
   ```

3. If Hugging Face requests authentication, sign in and accept any model terms shown on the
   [Gemma 4 E2B model page](https://huggingface.co/google/gemma-4-E2B-it):

   ```bash
   hf auth login
   ```

Never put a Hugging Face token in this repository or directly in a shell command.

## Prepare a short test file

Gemma 4 audio input is mono, 16 kHz, normalized float audio and is capped at 30 seconds. This
command produces a conservative WAV input and refuses to include audio after 30 seconds:

```bash
ffmpeg -i input.m4a -t 30 -ac 1 -ar 16000 -c:a pcm_f32le sample.wav
```

## Run a translation

Example for Hindi speech to English text:

```bash
uv run flowy-translate sample.wav --source Hindi --target English --output outputs/sample.md
```

The first invocation downloads the model and can take a while. It prints only the translated
text to stdout; model ID and elapsed inference time go to stderr.

If automatic placement fails, explicitly try the Apple GPU:

```bash
uv run flowy-translate sample.wav --source Hindi --target English --device mps --dtype float16
```

CPU inference is a diagnostic fallback, not the intended fast path:

```bash
uv run flowy-translate sample.wav --source Hindi --target English --device cpu --dtype float32
```

## Validate the local code without loading the model

```bash
uv run pytest
uv run ruff check .
```

## Known baseline constraints

- Audio beyond 30 seconds is not yet chunked and may be truncated by the processor.
- Transformers initializes Gemma's unified image processor even for audio-only requests, so
  Pillow is a required dependency despite not appearing in the minimal official audio install.
- Speaker diarization and timestamps are not part of this first direct-translation baseline.
- Translation can omit or invent content; a serious evaluation set must compare against human
  references and retain the original audio.
- `do_sample=False` improves repeatability but floating-point inference is not guaranteed to be
  bit-for-bit identical across devices or library versions.
- The first timing includes model download/load. Speed comparisons must separately report cold
  load, warm inference, audio duration, and real-time factor.
- A 16 GB machine has limited headroom for full BF16 weights and runtime allocations. If it does
  not fit reliably, the next experiment is a verified Apple-compatible quantized runtime—not a
  silent fallback that changes the baseline.

## Next milestone

After one clip translates successfully:

1. Record peak memory, warm latency, and translation quality.
2. Add voice-activity-based chunking with small overlaps and duplicate suppression.
3. Compare direct Gemma translation with a two-stage ASR-plus-translation pipeline.
4. Evaluate native Apple/MLX and quantized runtimes only where Gemma 4 audio is actually supported.
5. Wrap the winning engine behind a stable local API, then build the app.
