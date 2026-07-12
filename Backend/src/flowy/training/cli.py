"""Command-line entry point for Slive training-data preparation."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from flowy.training.store import LabelPolicy, TrainingStore, write_manifest


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="flowy-train",
        description="Inspect and prepare Slive's captured Whisper training data.",
    )
    parser.add_argument(
        "--store",
        type=Path,
        help=(
            "Training store root. Defaults to SLIVE_TRAINING_DIR or "
            "~/Library/Application Support/Slive/training."
        ),
    )

    subparsers = parser.add_subparsers(dest="command", required=True)
    inspect_parser = subparsers.add_parser("inspect", help="Validate the store read-only")
    _add_validation_arguments(inspect_parser)
    inspect_parser.add_argument("--json", action="store_true", help="Print the full JSON report")
    inspect_parser.add_argument(
        "--show-rejections",
        action="store_true",
        help="Print every rejected sample and reason in the human report",
    )

    manifest_parser = subparsers.add_parser(
        "build-manifest",
        help="Write eligible samples to a deterministic JSONL manifest",
    )
    _add_validation_arguments(manifest_parser)
    manifest_parser.add_argument("--output", type=Path, required=True)
    manifest_parser.add_argument(
        "--allow-empty",
        action="store_true",
        help="Write an empty manifest instead of failing when no samples are eligible",
    )
    return parser


def _add_validation_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--label-policy",
        choices=[item.value for item in LabelPolicy],
        default=LabelPolicy.VERIFIED.value,
        help=(
            "verified=finalText only; llm=llmTranscript only; "
            "best-available=finalText then llmTranscript. Raw transcript is never a label."
        ),
    )
    parser.add_argument("--min-duration", type=float, default=0.5)
    parser.add_argument("--max-duration", type=float, default=30.0)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    store = TrainingStore(args.store)
    try:
        report = store.inspect(
            label_policy=LabelPolicy(args.label_policy),
            min_duration=args.min_duration,
            max_duration=args.max_duration,
        )
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.command == "inspect":
        if args.json:
            print(json.dumps(report.to_dict(), indent=2, ensure_ascii=False))
        else:
            _print_human_report(report, show_rejections=args.show_rejections)
        return 0 if report.eligible_count else 1

    if args.command == "build-manifest":
        if not report.eligible_count and not args.allow_empty:
            _print_human_report(report, show_rejections=True)
            print("error: no eligible samples; manifest was not written", file=sys.stderr)
            return 1
        output = write_manifest(report, args.output)
        print(json.dumps({**report.summary_dict(), "manifest": str(output)}, indent=2))
        return 0

    raise AssertionError(f"unhandled command: {args.command}")


def _print_human_report(report, *, show_rejections: bool) -> None:
    summary = report.summary_dict()
    print(f"Store: {summary['store_root']}")
    print(f"Index: {summary['index_file']}")
    print(f"Label policy: {summary['label_policy']}")
    print(f"Rows: {summary['total_rows']}")
    print(f"Eligible: {summary['eligible_count']}")
    print(f"Rejected: {summary['rejected_count']}")
    print(
        "Eligible audio: "
        f"{summary['eligible_audio_seconds']:.3f}s "
        f"({summary['eligible_audio_minutes']:.3f} min)"
    )
    if summary["rejection_reason_counts"]:
        print("Rejection reasons:")
        for reason, count in sorted(summary["rejection_reason_counts"].items()):
            print(f"  {count:>4}  {reason}")
    if show_rejections:
        print("Rejected samples:")
        for item in report.rejected_samples:
            identity = item.id or f"line-{item.line_number or 'unknown'}"
            print(f"  {identity}: {', '.join(item.reasons)}")


if __name__ == "__main__":
    raise SystemExit(main())

