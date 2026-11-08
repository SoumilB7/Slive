"""Slive's local HTTP server — the Swift app is its only client.

Run with (the app does this itself, from Backend/.venv):

    cd Backend && uv run python -m flowy.server      # or: uv run slive-server

Serves 127.0.0.1:50711, to the local app only (loopback Host, no Origin):
    GET  /health                    {"status": "ok", "busy": bool}
    POST /assistant                 {"text"}
    POST /assistant/stream          NDJSON: {"delta"}… then {"done": true} or {"error"}
    POST /models                    {"models": [...]} — a provider's live list
    GET  /transcribe_llm/prompt     {"prompt"} — the default instruction
    POST /transcribe_llm            {"text", "prompt"} — ground truth from one model
    POST /label_consensus           {"text", "chosen", "agreement", "candidates", "prompt"}
    GET  /label_format/prompt       {"prompt"} — the formatter's instruction
    POST /label_format              {"formatted", "status", "model"} — step 4 of Custom 4
    GET  /local/cache               {"models": [...]} — the Hugging Face cache
    POST /local/download            {"job_id"}; poll GET /local/download/{id}
    POST /local/delete              {"deleted"}
    GET  /training/models | /training/readiness | /training/jobs/latest | /training/jobs/{id}
    POST /training/start | /training/jobs/{id}/resume   202 {"job"}
Errors are {"error": "<message>"} with the status from ``flowy.errors``.

No model loads at startup: dictation STT runs on-device (WhisperKit) in the
app, so an idle server costs a few tens of MB. Layout: ``api/`` (app factory,
routes, schemas), ``providers/`` (LLM registry), ``jobs/`` (background job
runner), ``training/``, ``local``/``local_infer`` (Hugging Face models),
``settings`` (env + paths), ``lifecycle`` (process + serving).
"""

from __future__ import annotations

from flowy.api import create_app, default_services
from flowy.lifecycle import serve
from flowy.settings import Settings

app = create_app(Settings.from_env(), default_services())


def main() -> None:
    serve(app)


if __name__ == "__main__":
    main()
