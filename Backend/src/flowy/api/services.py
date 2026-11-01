"""What the routes depend on, injected through ``create_app``.

The production services are the domain modules themselves (they already
expose these functions); tests pass fakes. Each Protocol is the exact surface
the routes use.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

from flowy.providers import Gateway


class Labeler(Protocol):
    async def label(self, *, api_key: str, audio_b64: str, media_type: str, typed: str,
                    hotwords: list[str] | str, context: str,
                    base_prompt: str) -> dict[str, Any]: ...


class LocalModels(Protocol):
    def list_cached_models(self) -> list[dict]: ...
    def delete_cached_model(self, repo_id: str) -> bool: ...
    def start_download(self, repo_id: str, token: str | None) -> str: ...
    def download_status(self, job_id: str) -> dict | None: ...
    def busy(self) -> bool: ...


class Job(Protocol):
    def to_dict(self) -> dict: ...


class Training(Protocol):
    def readiness(self) -> dict: ...
    def start_job(self, *, source_model: str, method: str, custom_name: str | None,
                  max_ram_gb: float) -> Job: ...
    def resume_job(self, job_id: str) -> Job: ...
    def latest_job(self) -> Job | None: ...
    def get_job(self, job_id: str) -> Job | None: ...
    def busy(self) -> bool: ...
    def recover_interrupted(self) -> int: ...


@dataclass
class Services:
    ai: Gateway
    labeler: Labeler
    local_models: LocalModels
    training: Training

    def busy(self) -> bool:
        """A background job is running (requests in flight are counted by the
        middleware)."""
        return self.local_models.busy() or self.training.busy()


def default_services() -> Services:
    from flowy import label_consensus, local
    from flowy.providers import default_gateway
    from flowy.training import jobs

    return Services(ai=default_gateway, labeler=label_consensus, local_models=local,
                    training=jobs)
