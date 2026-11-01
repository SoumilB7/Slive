"""Process lifecycle: process group, leaving with the app, logging, serving."""

from __future__ import annotations

import logging
import os
import signal
import threading
import time

logger = logging.getLogger("flowy.server")


def watch_parent(parent_pid: int, on_gone, interval: float = 2.0) -> None:
    """Call ``on_gone`` once the app that spawned us is gone. A crashed or
    force-quit app never runs its stop(), and we'd otherwise sit on the port
    (and RAM) until the next launch reaps us. Reparenting to launchd changes
    our ppid, so polling it needs no cooperation from the dead parent."""
    while os.getppid() == parent_pid:
        time.sleep(interval)
    on_gone()


def exit_with_app() -> None:
    """The app died: stop the way its stop() would — SIGTERM to our process
    group when we lead one (so a training converter goes too), else just us —
    and hard-exit if a clean uvicorn shutdown doesn't land in time."""
    logger.warning("Slive app is gone — shutting down.")
    try:
        if os.getpgrp() == os.getpid():
            os.killpg(os.getpid(), signal.SIGTERM)
        else:
            os.kill(os.getpid(), signal.SIGTERM)
    except OSError:
        pass
    time.sleep(10)
    os._exit(0)


def serve(app) -> None:
    """Run ``app`` (built by ``create_app``) until the app stops us."""
    import uvicorn

    settings = app.state.settings
    # Launched by the app: lead our own process group so the app's stop() can
    # signal us AND our children (the training converter) as one unit.
    if settings.own_process_group:
        try:
            os.setpgid(0, 0)
        except OSError:
            pass
    # The app passes its pid so we leave with it, crash included.
    if settings.parent_pid > 1:
        threading.Thread(
            target=watch_parent, args=(settings.parent_pid, exit_with_app), daemon=True
        ).start()

    logging.basicConfig(level=logging.INFO)
    # Jobs live in memory: mark runs a previous server died during as
    # interrupted (and reload past jobs) before the app asks for them.
    try:
        app.state.services.training.recover_interrupted()
    except OSError:
        logger.warning("Training-run recovery failed", exc_info=True)
    # httpx/httpcore log every request URL at INFO — keep provider traffic
    # (and anything a URL could ever carry) out of the backend log.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    uvicorn.run(app, host=settings.host, port=settings.port, log_level="info")
