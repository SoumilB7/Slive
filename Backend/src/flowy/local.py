"""Local (Hugging Face) models — download into the standard HF cache and read
what's there.

Everything runs in this Python backend. Downloads land in the **exact same
cache** the `transformers` / `huggingface_hub` / PyTorch ecosystem uses
(`HF_HOME` → `~/.cache/huggingface/hub` by default), so anything already pulled
by other tools shows up here, and anything pulled here is usable by them.

This module owns the download + cache-inventory half; running a downloaded
model lives in ``local_infer``.
"""

from __future__ import annotations

import uuid
from dataclasses import asdict, dataclass

from flowy.jobs import JobRunner
from flowy.util import error_text

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
        from huggingface_hub import scan_cache_dir

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
    from huggingface_hub import scan_cache_dir

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


downloads: JobRunner[_Job] = JobRunner()


def busy() -> bool:
    """A download is still running (the app must not idle-stop the server)."""
    return downloads.busy()


def start_download(repo_id: str, token: str | None) -> str:
    """Kick off a background ``snapshot_download`` into the standard cache and
    return a job id to poll. A gated (private) repo without a valid token
    surfaces as the job's error message."""
    job = downloads.add(_Job(id=uuid.uuid4().hex, repo_id=repo_id))

    def run() -> None:
        try:
            from huggingface_hub import snapshot_download

            path = snapshot_download(repo_id=repo_id, token=token or None)
            downloads.update(job.id, state="done", path=path)
        except Exception as exc:  # noqa: BLE001 - report any HF error to the UI
            downloads.update(job.id, state="error", message=error_text(exc, 400))

    downloads.spawn(run)
    return job.id


def download_status(job_id: str) -> dict | None:
    """Current state of a download job, or None if the id is unknown."""
    with downloads.lock:
        job = downloads.jobs.get(job_id)
        return asdict(job) if job else None
