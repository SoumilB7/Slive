"""Local generation holds the model lock, so a switch can't free it mid-use."""

import threading

from flowy import local_infer


def _fake_loaded() -> local_infer._Loaded:
    return local_infer._Loaded("a/b", True, object(), object(), False, False, False)


def _lock_free_elsewhere() -> bool:
    """Whether another thread could take the lock right now."""
    result: dict[str, bool] = {}

    def probe() -> None:
        got = local_infer._lock.acquire(blocking=False)
        if got:
            local_infer._lock.release()
        result["free"] = got

    t = threading.Thread(target=probe)
    t.start()
    t.join()
    return result["free"]


def test_chat_holds_lock_through_generation(monkeypatch) -> None:
    observed: list[bool] = []
    monkeypatch.setattr(local_infer, "_load", lambda *a, **k: _fake_loaded())

    def fake_generate(loaded, messages, max_tokens):
        observed.append(_lock_free_elsewhere())
        return "answer"

    monkeypatch.setattr(local_infer, "_generate", fake_generate)
    assert local_infer.chat("a/b", None, "", [], "hi", []) == "answer"
    assert observed == [False]
    assert _lock_free_elsewhere()


def test_unload_inside_generation_does_not_deadlock(monkeypatch) -> None:
    # An OOM in _generate calls unload() while the entry point holds the lock.
    monkeypatch.setattr(local_infer, "_load", lambda *a, **k: _fake_loaded())
    monkeypatch.setattr(local_infer, "_free_accelerator", lambda: None)

    def fake_generate(loaded, messages, max_tokens):
        local_infer.unload()
        return "ok"

    monkeypatch.setattr(local_infer, "_generate", fake_generate)
    assert local_infer.chat("a/b", None, "", [], "hi", []) == "ok"
