"""In-memory background jobs: the bookkeeping local downloads and training share.

A ``JobRunner`` holds jobs by id (insertion-ordered, so the last one added is
the latest), guards them with one lock, runs work on daemon threads, and
answers ``busy()`` for ``/health`` so the app's idle shutdown never kills a
running job. Job objects are plain dataclasses with a ``state`` field; what
the work does, and what JSON the poll route returns, stay with the owner.
"""

from __future__ import annotations

import threading
from collections.abc import Callable, Iterable
from typing import Any


class JobRunner[J]:
    def __init__(
        self,
        active_states: Iterable[str] = ("running",),
        persist: Callable[[J], None] | None = None,
    ) -> None:
        """``active_states``: the states that count as busy. ``persist``: called
        with the job (lock held) after every ``mutate`` — e.g. write job.json."""
        self.active_states = frozenset(active_states)
        self.persist = persist
        #: Never reassigned — owners may alias it (``_jobs = runner.jobs``).
        self.jobs: dict[str, J] = {}
        #: Re-entrant so a compound check-then-add (``with runner.lock:``) can
        #: call the methods below.
        self.lock = threading.RLock()

    def add(self, job: J) -> J:
        with self.lock:
            self.jobs[job.id] = job  # type: ignore[attr-defined]
        return job

    def get(self, job_id: str) -> J | None:
        with self.lock:
            return self.jobs.get(job_id)

    def latest(self) -> J | None:
        with self.lock:
            return next(reversed(self.jobs.values()), None) if self.jobs else None

    def active(self) -> J | None:
        """The first queued/running job, if any."""
        with self.lock:
            return next(
                (j for j in self.jobs.values() if j.state in self.active_states),  # type: ignore[attr-defined]
                None,
            )

    def busy(self) -> bool:
        """A job is still active (the app must not idle-stop the server)."""
        return self.active() is not None

    def mutate(self, job_id: str, change: Callable[[J], Any]) -> None:
        """Apply ``change`` to the job under the lock, then persist it."""
        with self.lock:
            job = self.jobs[job_id]
            change(job)
            if self.persist is not None:
                self.persist(job)

    def update(self, job_id: str, **fields: Any) -> None:
        """Set fields on the job (``mutate`` for the common case)."""

        def apply(job: J) -> None:
            for key, value in fields.items():
                setattr(job, key, value)

        self.mutate(job_id, apply)

    def restore(self, jobs: Iterable[J]) -> None:
        """Reload jobs a previous server left on disk; ids already known win."""
        with self.lock:
            for job in jobs:
                self.jobs.setdefault(job.id, job)  # type: ignore[attr-defined]

    @staticmethod
    def spawn(target: Callable[..., None], *args: Any, name: str | None = None,
              **kwargs: Any) -> None:
        """Run ``target`` on a daemon thread (blocking work stays off the loop)."""
        threading.Thread(target=target, args=args, kwargs=kwargs, name=name, daemon=True).start()
