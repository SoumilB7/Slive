"""Local (Hugging Face) models — download into the standard cache + read it."""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.concurrency import run_in_threadpool

from flowy.api.routes import ServicesDep
from flowy.api.schemas import LocalDeleteRequest, LocalDownloadRequest
from flowy.errors import BadRequest, NotFound

router = APIRouter()


@router.get("/local/cache")
async def local_cache(services: ServicesDep):
    """List the model repos currently in the HF cache (fast, no network)."""
    models = await run_in_threadpool(services.local_models.list_cached_models)
    return {"models": models}


@router.post("/local/download")
async def local_download(req: LocalDownloadRequest, services: ServicesDep):
    """Start a background snapshot download; returns a job id to poll. Validates
    the id in the handler (not a pydantic validator) so a bad id returns a clean
    {error} the app can show, not a 422 the client would mis-read."""
    repo_id = req.repo_id.strip()
    if not repo_id or "/" not in repo_id or any(ord(c) < 0x20 for c in repo_id):
        raise BadRequest("Enter a model id like 'owner/name'.")
    token = (req.token or "").strip() or None
    return {"job_id": services.local_models.start_download(repo_id, token)}


@router.get("/local/download/{job_id}")
async def local_download_status(job_id: str, services: ServicesDep):
    status = services.local_models.download_status(job_id)
    if status is None:
        raise NotFound("Unknown job.")
    return status


@router.post("/local/delete")
async def local_delete(req: LocalDeleteRequest, services: ServicesDep):
    ok = await run_in_threadpool(services.local_models.delete_cached_model, req.repo_id)
    if not ok:
        raise NotFound("Not in the cache.")
    return {"deleted": req.repo_id}
