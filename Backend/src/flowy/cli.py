from __future__ import annotations

import argparse
import sys
from pathlib import Path

from flowy.core import DEFAULT_MODEL_ID, GemmaTranslator


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Translate a short audio clip locally with Gemma 4 E2B."
    )
    parser.add_argument("audio", type=Path, help="Audio file (30 seconds or shorter)")
    parser.add_argument("--source", required=True, help="Spoken source language")
    parser.add_argument("--target", default="English", help="Translation language")
    parser.add_argument("--model", default=DEFAULT_MODEL_ID, help="Hugging Face model ID")
    parser.add_argument("--device", default="auto", help="auto, mps, or cpu")
    parser.add_argument("--dtype", default="auto", help="Transformers dtype")
    parser.add_argument("--max-new-tokens", type=int, default=512)
    parser.add_argument("--output", type=Path, help="Write translation to this UTF-8 file")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    translator = GemmaTranslator(args.model, args.device, args.dtype)
    try:
        result = translator.translate(
            args.audio,
            args.source,
            args.target,
            max_new_tokens=args.max_new_tokens,
        )
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(result.text + "\n", encoding="utf-8")
    print(result.text)
    print(f"\n[model={result.model_id} elapsed={result.elapsed_seconds:.2f}s]", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

