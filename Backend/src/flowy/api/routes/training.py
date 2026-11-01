"""Whisper fine-tuning — readiness + one local background job.

Status codes the app relies on: 202 started, 404 unknown job, 409 conflict
(already training, name taken), 422 bad input, 424 missing dependency
(converter, disk)."""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.concurrency import run_in_threadpool

from flowy.api.routes import ServicesDep
from flowy.api.schemas import TrainingStartRequest
from flowy.errors import NotFound, invalid_as_unprocessable
from flowy.training.models import training_models_payload

router = APIRouter()


@router.get("/training/models")
async def training_models():
    return {"models": training_models_payload()}


@router.get("/training/readiness")
async def training_readiness(services: ServicesDep):
    """Report whether the current Slive training store has the required 50 rows."""
    return await run_in_threadpool(services.training.readiness)


@router.post("/training/start", status_code=202)
async def training_start(req: TrainingStartRequest, services: ServicesDep):
    """Start LoRA training through merge, WhisperKit conversion, and install."""
    with invalid_as_unprocessable():
        # start_job runs readiness(), which hashes every clip — off the loop.
        job = await run_in_threadpool(
            services.training.start_job,
            source_model=req.source_model,
            method=req.method,
            custom_name=req.name,
            max_ram_gb=req.max_ram_gb,
        )
    return {"job": job.to_dict()}


@router.post("/training/jobs/{job_id}/resume", status_code=202)
async def training_resume(job_id: str, services: ServicesDep):
    """Finish a run that failed after training (merge → convert → install)."""
    with invalid_as_unprocessable():
        job = await run_in_threadpool(services.training.resume_job, job_id)
    return {"job": job.to_dict()}


@router.get("/training/jobs/latest")
async def training_latest_job(services: ServicesDep):
    job = services.training.latest_job()
    return {"job": job.to_dict() if job else None}


@router.get("/training/jobs/{job_id}")
async def training_job(job_id: str, services: ServicesDep):
    job = services.training.get_job(job_id)
    if job is None:
        raise NotFound("Unknown training job.")
    return {"job": job.to_dict()}
