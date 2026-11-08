"""Every registered provider × every key state × streaming on/off × model
lists, through the real routes and gateway with only the wire faked.

The provider list is read from ``default_registry()`` at collection time, so
a new provider is parametrized automatically — and fails
``test_every_registered_provider_has_a_fake`` until ``matrix_support``
knows how to fake it. Nothing here touches the network or loads a model."""

from __future__ import annotations

import pytest

from flowy import local_infer
from flowy.providers import default_registry
from matrix_support import (
    AUDIO,
    LOCAL,
    ON_DEVICE,
    WIRES,
    OnDevice,
    Wire,
    assert_error,
    fake_for,
    read_ndjson,
    swift_provider_specs,
    swift_source,
    wire_handler,
)

pytestmark = pytest.mark.usefixtures("deadline")

REGISTRY = default_registry()
PROVIDERS = REGISTRY.names()
#: missing = no key typed; invalid = the provider rejects it (its auth error).
KEYS = {"present": "sk-test-key", "missing": "", "invalid": "sk-revoked"}
#: What the upstream answers: words, a 2xx with no words, or a failure.
REPLIES = ("text", "empty", "broken")
TEXT = "Hello there"
DELTAS = ("Hel", "lo there")


def _requires_key(name: str) -> bool:
    return REGISTRY.get(name).requires_key


def _hears(name: str) -> bool:
    fake = fake_for(name)
    return isinstance(fake, OnDevice) or fake.audio is not None


def _lists_models(name: str) -> bool:
    return isinstance(fake_for(name), Wire)


@pytest.fixture
def upstream(fake_http, monkeypatch):
    """Install the fake for ``name`` (HTTP wire or on-device engine)."""

    def install(name: str, *, key: str, reply: str, **wire_options):
        fake = fake_for(name)
        if isinstance(fake, Wire):
            return fake_http(wire_handler(fake, key=key, reply=reply, text=TEXT, deltas=DELTAS,
                                          **wire_options))

        def engine(*_args, **_kwargs):
            if key == "invalid":
                raise local_infer.LocalInferenceError(fake.auth_error)
            if reply == "broken":
                raise RuntimeError("MPS backend crashed")
            return "" if reply == "empty" else TEXT

        monkeypatch.setattr(local_infer, "chat", engine)
        monkeypatch.setattr(local_infer, "transcribe", engine)
        return fake_http(None)  # any HTTP call from an on-device provider fails loudly

    return install


def _body(name: str, key: str, **extra) -> dict:
    return {"text": "hi", "provider": name, "model": "m", "api_key": KEYS[key],
            **fake_for(name).extra, **extra}


def _expected_failure(name: str, key: str, reply: str) -> tuple[int, str] | None:
    """(status, message fragment) the route must answer with, or None for success."""
    if key == "missing" and _requires_key(name):
        return 400, "Missing api_key"
    on_device = isinstance(fake_for(name), OnDevice)
    if key == "invalid":
        return (400, LOCAL.auth_error) if on_device else (400, "(401)")
    if reply == "broken":
        return (502, "MPS backend crashed") if on_device else (400, "(503)")
    return None


# --- completeness --------------------------------------------------------------

def test_every_registered_provider_has_a_fake() -> None:
    for name in PROVIDERS:
        fake_for(name)
    assert set(WIRES) | set(ON_DEVICE) == set(PROVIDERS), "a fake for a provider that no longer exists"
    assert not set(WIRES) & set(ON_DEVICE)


def test_swift_catalog_matches_the_registry() -> None:
    """The app's ProviderCatalog sends exactly the registry's names, and each
    capability it advertises is one the server honours."""
    source = swift_source("Providers/ProviderSpec.swift")
    if source is None:
        pytest.skip("Frontend sources not present")
    specs = swift_provider_specs(source)
    sent = {wire: caps for wire, caps in specs.items() if "chat" in caps}
    assert set(sent) == set(PROVIDERS)
    for name, caps in sent.items():
        assert ("needsKey" in caps) == _requires_key(name), name
        assert ("listModels" in caps) == _lists_models(name), name
        assert ("audioTranscribe" in caps) == _hears(name), name
        assert ("needsBaseURL" in caps) == ("base_url" in fake_for(name).extra), name


# --- /assistant and /assistant/stream ------------------------------------------

@pytest.mark.parametrize("reply", REPLIES)
@pytest.mark.parametrize("stream", [False, True], ids=["oneshot", "stream"])
@pytest.mark.parametrize("key", KEYS)
@pytest.mark.parametrize("name", PROVIDERS)
def test_assistant(real_client, upstream, name, key, stream, reply) -> None:
    upstream(name, key=key, reply=reply)
    resp = real_client.post("/assistant/stream" if stream else "/assistant", json=_body(name, key))
    failure = _expected_failure(name, key, reply)
    on_device = isinstance(fake_for(name), OnDevice)

    if not stream:
        if failure:
            status, fragment = failure
            assert fragment in assert_error(resp, status)
        else:
            assert (resp.status_code, resp.json()) == (200, {"text": "" if reply == "empty" else TEXT})
        return

    events = read_ndjson(resp)
    if failure:
        assert len(events) == 1 and failure[1] in events[0]["error"], events
    elif reply == "empty":
        label = REGISTRY.get(name).label(fake_for(name).extra.get("base_url"))
        assert events == [{"error": f"{label} returned an empty answer — try again."}]
    else:
        deltas = [TEXT] if on_device else list(DELTAS)
        assert events == [*({"delta": d} for d in deltas), {"done": True}]


@pytest.mark.parametrize("name", [n for n in PROVIDERS if isinstance(fake_for(n), Wire)])
def test_stream_error_event_after_partial_text(real_client, upstream, name) -> None:
    """A provider's mid-stream error (overloaded, rate limit) keeps the text
    already sent and ends the stream with an error line, not a cut-off."""
    upstream(name, key="present", reply="text", cut=True)
    events = read_ndjson(real_client.post("/assistant/stream", json=_body(name, "present")))
    assert events[:-1] == [{"delta": d} for d in DELTAS]
    assert "error" in events[-1]


@pytest.mark.parametrize("name", PROVIDERS)
def test_stream_body_validation_is_a_422_not_a_broken_stream(real_client, upstream, name) -> None:
    upstream(name, key="present", reply="text")
    resp = real_client.post("/assistant/stream", json=_body(name, "present", api_key="k\x00"))
    assert_error(resp, 422)


# --- /models ---------------------------------------------------------------------

#: normal = the provider's usual list (with ids its filter drops); empty = no
#: models; absent = a 2xx without the list at all.
MODEL_LISTS = ("normal", "empty", "absent")


@pytest.mark.parametrize("models", MODEL_LISTS)
@pytest.mark.parametrize("key", KEYS)
@pytest.mark.parametrize("name", PROVIDERS)
def test_models(real_client, upstream, name, key, models) -> None:
    fake = fake_for(name)
    ids = getattr(fake, "model_ids", []) if models == "normal" else []
    upstream(name, key=key, reply="text", model_ids=ids,
             models_payload={} if models == "absent" else None)
    body = {"provider": name, "api_key": KEYS[key]}
    if "base_url" in fake.extra:
        body["base_url"] = fake.extra["base_url"]
    resp = real_client.post("/models", json=body)

    if key == "missing":  # every provider, the on-device one included
        assert assert_error(resp, 400) == "Missing api_key"
    elif not _lists_models(name):
        assert assert_error(resp, 400) == f"Unknown provider: {name}"
    elif key == "invalid":
        assert "(401)" in assert_error(resp, 400)
    else:
        assert (resp.status_code, resp.json()) == (200, {"models": fake.listed(ids)})


# --- /transcribe_llm (the single-provider ground truth) ---------------------------

@pytest.mark.parametrize("reply", REPLIES)
@pytest.mark.parametrize("key", KEYS)
@pytest.mark.parametrize("name", PROVIDERS)
def test_transcribe_llm(real_client, upstream, name, key, reply) -> None:
    upstream(name, key=key, reply=reply)
    body = {"provider": name, "model": "m", "api_key": KEYS[key], "audio_b64": AUDIO,
            **fake_for(name).extra}
    resp = real_client.post("/transcribe_llm", json=body)

    failure = _expected_failure(name, key, reply)
    if failure and failure[1] == "Missing api_key":
        assert assert_error(resp, 400) == "Missing api_key"
    elif not _hears(name):
        assert "do not accept audio" in assert_error(resp, 400)
    elif failure:
        assert failure[1] in assert_error(resp, failure[0])
    else:
        payload = resp.json()
        assert resp.status_code == 200 and set(payload) == {"text", "prompt"}, payload
        # An empty transcript is a 200 the app reports as "No text returned."
        assert payload["text"] == ("" if reply == "empty" else TEXT)
        assert isinstance(payload["prompt"], str) and payload["prompt"].strip()


# --- base_url ------------------------------------------------------------------------

ROUTES = {
    "assistant": lambda name: ("/assistant", _body(name, "present")),
    "stream": lambda name: ("/assistant/stream", _body(name, "present")),
    "models": lambda name: ("/models", {"provider": name, "api_key": KEYS["present"]}),
    "transcribe_llm": lambda name: ("/transcribe_llm", {
        "provider": name, "model": "m", "api_key": KEYS["present"], "audio_b64": AUDIO}),
}


@pytest.mark.parametrize("route", ROUTES)
@pytest.mark.parametrize("name", [n for n in PROVIDERS if "base_url" in fake_for(n).extra])
def test_a_missing_base_url_is_a_readable_400(real_client, upstream, name, route) -> None:
    upstream(name, key="present", reply="text")
    path, body = ROUTES[route](name)
    body.pop("base_url", None)
    resp = real_client.post(path, json=body)
    message = f"base_url is required for {name}"
    if route == "stream":
        assert read_ndjson(resp) == [{"error": message}]
    else:
        assert assert_error(resp, 400) == message
