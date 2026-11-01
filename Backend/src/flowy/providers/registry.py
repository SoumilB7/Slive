"""Provider lookup by the id the app sends.

Adding a provider: write ``providers/<name>.py`` with a class satisfying
``base.Provider`` (``name``, ``requires_key``, ``label``, ``chat``,
``stream``, ``list_models``, ``transcribe_audio`` — raise ValueError for a
capability it lacks), then add one instance to ``default_registry`` below.
The routes, the NDJSON framing and the error mapping need no change.
"""

from __future__ import annotations

from collections.abc import Iterable

from flowy.providers.anthropic import AnthropicProvider
from flowy.providers.base import Provider
from flowy.providers.gemini import GeminiProvider
from flowy.providers.local import LocalProvider
from flowy.providers.openai import OpenAICompatibleProvider, OpenAIProvider


class ProviderRegistry:
    def __init__(self, providers: Iterable[Provider] = ()) -> None:
        self._by_name: dict[str, Provider] = {}
        for provider in providers:
            self.register(provider)

    def register(self, provider: Provider) -> None:
        self._by_name[provider.name] = provider

    def get(self, name: str) -> Provider | None:
        return self._by_name.get(name)

    def names(self) -> list[str]:
        return list(self._by_name)

    def resolve(self, name: str, api_key: str) -> Provider:
        """The provider for ``name``. A missing key is reported before an
        unknown name (the order the app has always seen); providers that need
        no key (local) skip that check."""
        provider = self._by_name.get(name)
        if (provider is None or provider.requires_key) and not api_key:
            raise ValueError("Missing api_key")
        if provider is None:
            raise ValueError(f"Unknown provider: {name}")
        return provider


def default_registry() -> ProviderRegistry:
    return ProviderRegistry([
        AnthropicProvider(),
        OpenAIProvider(),
        OpenAICompatibleProvider(),
        GeminiProvider(),
        LocalProvider(),
    ])
