"""Local (Hugging Face) models — download into the standard HF cache and read
what's there.

Everything runs in this Python backend. Downloads land in the **exact same
cache** the `transformers` / `huggingface_hub` / PyTorch ecosystem uses
(`HF_HOME` → `~/.cache/huggingface/hub` by default), so anything already pulled
by other tools shows up here, and anything pulled here is usable by them.

Model *inference* (loading + running a downloaded model) is the next milestone;
this module owns the download + cache-inventory half.
"""

from __future__ import annotations

import threading
import uuid
from dataclasses import asdict, dataclass

from huggingface_hub import scan_cache_dir, snapshot_download


# ---------------------------------------------------------------------------
# Cache inventory — read what's already downloaded
# ---------------------------------------------------------------------------

def list_cached_models() -> list[dict]:
    """Every model repo currently in the HF cache, largest first.

    Reads the real on-disk cache via ``scan_cache_dir`` — the same inventory
    ``huggingface-cli scan-cache`` shows — so the user sees exactly what they
    already have, regardless of which tool downloaded it.
    """
    try:
        info = scan_cache_dir()
    except Exception:  # noqa: BLE001 - a missing/empty cache is just "nothing"
        return []

    models: list[dict] = []
    for repo in info.repos:
        if repo.repo_type != "model":
            continue
        models.append(
            {
                "repo_id": repo.repo_id,
                "size_bytes": int(repo.size_on_disk),
                "nb_files": int(repo.nb_files),
                "last_modified": float(repo.last_modified or 0),
            }
        )
    models.sort(key=lambda m: m["size_bytes"], reverse=True)
    return models


def delete_cached_model(repo_id: str) -> bool:
    """Remove every cached revision of ``repo_id``. Returns False if not found."""
    info = scan_cache_dir()
    hashes = [
        rev.commit_hash
        for repo in info.repos
        if repo.repo_id == repo_id and repo.repo_type == "model"
        for rev in repo.revisions
    ]
    if not hashes:
        return False
    info.delete_revisions(*hashes).execute()
    return True


# ---------------------------------------------------------------------------
# Downloads — background jobs (snapshot_download blocks for minutes)
# ---------------------------------------------------------------------------

@dataclass
class _Job:
    id: str
    repo_id: str
    state: str = "running"   # running | done | error
    message: str = ""
    path: str | None = None


_jobs: dict[str, _Job] = {}
_lock = threading.Lock()


def start_download(repo_id: str, token: str | None) -> str:
    """Kick off a background ``snapshot_download`` into the standard cache and
    return a job id to poll. A gated (private) repo without a valid token
    surfaces as the job's error message."""
    job = _Job(id=uuid.uuid4().hex, repo_id=repo_id)
    with _lock:
        _jobs[job.id] = job

    def run() -> None:
        try:
            path = snapshot_download(repo_id=repo_id, token=token or None)
            with _lock:
                job.state, job.path = "done", path
        except Exception as exc:  # noqa: BLE001 - report any HF error to the UI
            with _lock:
                job.state, job.message = "error", _short(exc)

    threading.Thread(target=run, daemon=True).start()
    return job.id


def download_status(job_id: str) -> dict | None:
    """Current state of a download job, or None if the id is unknown."""
    with _lock:
        job = _jobs.get(job_id)
        return asdict(job) if job else None


def _short(exc: Exception) -> str:
    text = str(exc).strip() or exc.__class__.__name__
    return text[:400]
