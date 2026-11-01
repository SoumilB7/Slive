import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

/// Provider model (Local runs keyless, on-device)
@MainActor
enum ProviderTests {
    static let suite = TestSuite(name: "Providers") { t in
        print("[Providers]")
        t.equal(AssistantProvider.local.wire, "local", "local wire value")
        t.check(!AssistantProvider.local.needsAPIKey && AssistantProvider.local.isLocal,
              "local is keyless and flagged local")
        t.check(AssistantProvider.allCases.filter { $0 != .local && $0 != .whisper }
                .allSatisfy(\.needsAPIKey),
              "every cloud provider needs a key")
        t.check(!AssistantProvider.whisper.needsAPIKey
                && !AssistantProvider.assistantChoices.contains(.whisper),
              "whisper is keyless and never an assistant choice")
        t.check(AssistantProvider.whisper.defaultModel == "large-v3",
              "whisper ground truth defaults to the Accurate judge")
        t.check(!AssistantProvider.local.needsBaseURL, "local needs no base URL")
        // The floor that separates runnable downloads from config-only repos —
        // shared by the Models page and both model pickers.
        t.equal(LocalCachedModel.minPickableBytes, 50 * 1_048_576, "local pickable size floor")
        var config = AssistantConfig.default
        config.provider = .local
        t.equal(config.model(for: .local), "", "local has no default model — must be picked")
        config.setModel("google/gemma-3n-E2B-it", for: .local)
        t.equal(config.model(for: .local), "google/gemma-3n-E2B-it", "local model override sticks")
    }
}
