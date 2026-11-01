import Foundation

/// What the assistant needs from the server side: the lazily spawned local
/// backend and the LLM proxy (`ServerAssistant`; a fake in the self-tests).
@MainActor protocol AssistantService {
    /// Bring the backend up (spawning it on first use). False if it couldn't.
    func ensureHealthy() async -> Bool
    /// Why the last spawn couldn't even start, if it couldn't.
    var lastSpawnError: String? { get }
    func apiKey(for provider: AssistantProvider) -> String
    func askStream(_ question: String, config: AssistantConfig, apiKey: String,
                   images: [AssistantClient.ImageInput]?,
                   history: [AssistantClient.HistoryItem]?) -> AsyncThrowingStream<String, Error>
}

/// The app's assistant: `BackendManager` + `AssistantClient`, keys from the
/// Keychain through Settings.
struct ServerAssistant: AssistantService {
    let backend: BackendManager
    let client: AssistantClient
    let settings: Settings

    func ensureHealthy() async -> Bool { await backend.ensureHealthy() }
    var lastSpawnError: String? { backend.lastSpawnError }
    func apiKey(for provider: AssistantProvider) -> String { settings.apiKey(for: provider) }
    func askStream(_ question: String, config: AssistantConfig, apiKey: String,
                   images: [AssistantClient.ImageInput]?,
                   history: [AssistantClient.HistoryItem]?) -> AsyncThrowingStream<String, Error> {
        client.askStream(question, config: config, apiKey: apiKey, images: images, history: history)
    }
}

/// The assistant: the transcribed question goes to the LLM; the answer
/// streams into the overlay and can be continued as a chat. Records like a
/// dictation (`HoldCapture`); owns the chat.
@MainActor final class AssistMode: RecordingRoute {
    typealias Screenshot = (mediaType: String, data: String)

    static let action = HotkeyAction.assist
    let listenKind = OverlayState.ListenKind.assistant
    let logLabel = "assistant"
    let droppedByDismiss = true

    private let ctx: ModeContext
    private let capture: HoldCapture
    private let assistant: AssistantService
    private let screenshot: @Sendable () -> Screenshot?
    /// The in-memory conversation (never persisted).
    private(set) var chat = ChatSession()

    init(_ ctx: ModeContext, assistant: AssistantService,
         screenshot: @escaping @Sendable () -> Screenshot? = { ScreenCapture.fullScreenBase64() }) {
        self.ctx = ctx
        capture = HoldCapture(ctx: ctx)
        self.assistant = assistant
        self.screenshot = screenshot
        ctx.presenter.model.onContinue = { [weak self] in self?.continueChat() }
    }

    func begin() { capture.begin(self) }
    func end() { capture.end(self) }
    func cancel() { capture.cancel() }
    var isCapturing: Bool { capture.isCapturing }

    /// ✕: drop the waiting assistant requests (dictations still type) and
    /// end the chat.
    func dismiss() {
        ctx.queue.cancelAssists()
        chat.end()
    }

    func willRecord() {
        // Boot the lazy backend NOW, overlapped with the user speaking —
        // by release it's healthy and the answer path skips the
        // multi-second first-use spawn entirely.
        let assistant = self.assistant
        Task { _ = await assistant.ensureHealthy() }
    }

    /// Capture the screenshot IN PARALLEL with transcription — both happen
    /// post-release, and the screencapture subprocess used to sit serially
    /// (~200-500ms) in front of the HTTP request.
    func prepare() -> Task<Screenshot?, Never>? {
        guard ctx.settings.assistantConfig.attachScreenshot else { return nil }
        let screenshot = self.screenshot
        return Task.detached(priority: .userInitiated) { screenshot() }
    }

    func deliver(_ release: DecodedRelease, prepared screenshotTask: Task<Screenshot?, Never>?) async {
        if let queueID = release.queueID {
            // Hand the turn on NOW that the question is in hand — the
            // LLM stream runs for seconds and held every later
            // dictation behind it. From here it's an ordinary in-flight
            // answer: a newer hold or ✕ cancels it via the in-flight request.
            let owns = ctx.ownsOverlay(queueID)
            let mine = ctx.queue.handOff(queueID)
            guard owns else {
                // A newer hold / dictation has the overlay: it
                // supersedes this request, as it would an unqueued one.
                Log.event("queued assistant request superseded by a newer hold — skipped")
                screenshotTask?.cancel()
                return
            }
            ctx.work.request?.cancel()
            ctx.work.request = mine
        }
        if await assistant.ensureHealthy() {
            if Task.isCancelled { return }
            await runAssistant(on: release.text, screenshot: screenshotTask)
        } else {
            screenshotTask?.cancel()
            await MainActor.run { self.showBackendError() }
        }
    }

    // MARK: - Answer

    /// Assistant path: stream the LLM's answer into a fixed-size box, growing
    /// the text as tokens arrive, then settle the box to the final size.
    func runAssistant(on transcript: String, screenshot screenshotTask: Task<Screenshot?, Never>? = nil) async {
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            ctx.presenter.hideSoon(); return
        }
        let config = ctx.settings.assistantConfig
        let key = assistant.apiKey(for: config.provider)

        // Continue the previous chat only if the user tapped "Continue" after the
        // last answer; otherwise this is a fresh conversation.
        let history = chat.beginRequest()

        // The screenshot was kicked off in parallel with transcription (see
        // `prepare`); by now it's usually already done — awaiting it here is
        // ~free instead of a serial ~200-500ms subprocess before the request.
        var images: [AssistantClient.ImageInput]? = nil
        if config.attachScreenshot {
            let shot: Screenshot?
            if let screenshotTask {
                shot = await screenshotTask.value
            } else {
                // No pre-capture (e.g. setting flipped mid-flight) — capture now.
                let screenshot = self.screenshot
                shot = await Task.detached(priority: .userInitiated, operation: {
                    screenshot()
                }).value
            }
            if let shot {
                images = [AssistantClient.ImageInput(media_type: shot.mediaType, data: shot.data)]
            }
        }

        // Switch the overlay to the streaming answer box. When continuing, show
        // the prior turns above the new answer so it reads as one conversation.
        ctx.presenter.streaming(priorTurns: chat.priorTurns, question: question)

        var accumulated = ""
        var lastRender = Date.distantPast
        do {
            for try await delta in assistant.askStream(
                question, config: config, apiKey: key, images: images, history: history
            ) {
                if Task.isCancelled { return }
                accumulated += delta
                // Tokens often arrive in bursts; draining them straight through
                // on the main actor coalesces into a single paint. Update at most
                // ~30fps and briefly yield to the run loop so each frame actually
                // draws — the answer visibly types out.
                if Date().timeIntervalSince(lastRender) >= 0.033 {
                    lastRender = Date()
                    ctx.presenter.updateStreaming(accumulated)
                    try? await Task.sleep(nanoseconds: 3_000_000)
                }
            }
        } catch {
            if Task.isCancelled { return }
            let shown = accumulated.isEmpty ? "\(error)" : accumulated + "\n\n\(error)"
            showAssistantError(shown)
            return
        }
        if Task.isCancelled { return }
        finalizeAssist(question: question, answer: accumulated)
    }

    /// Settle the streamed answer into a final, text-sized box with a Continue
    /// footer, remember the turn (for a possible continuation), and record it.
    private func finalizeAssist(question: String, answer: String) {
        ctx.work.endDictationActivityIfIdle()
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            chat.dropPending(); ctx.presenter.hideSoon(); return
        }
        ctx.records.addToHistory(trimmed)
        chat.answered(question: question, answer: trimmed)
        ctx.presenter.answer(trimmed)
    }

    /// Show an assistant failure (no Continue footer) and collapse soon.
    private func showAssistantError(_ text: String) {
        chat.dropPending()
        ctx.presenter.result(text, isError: true, collapseAfter: 6.0)
    }

    /// User tapped "Continue": stash this turn into the conversation and hide the
    /// box (keeping chat state) so the next assistant keybind continues it.
    func continueChat() {
        chat.continueChat()
        ctx.presenter.dismiss()   // hide() resets the model (chat state lives here, untouched)
    }

    /// Shown when the backend couldn't be brought up in time — a clear message
    /// instead of an empty result.
    private func showBackendError() {
        ctx.work.endDictationActivityIfIdle()
        // A spawn that can't start says what to fix — retrying never helps it.
        let msg = assistant.lastSpawnError ?? "Starting up. Try again shortly."
        ctx.presenter.result(msg, collapseAfter: 3.5)
    }
}
