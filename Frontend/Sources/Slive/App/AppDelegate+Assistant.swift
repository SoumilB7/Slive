import AppKit

/// The assistant: the transcribed question goes to the LLM; the answer
/// streams into the overlay and can be continued as a chat.
extension AppDelegate {
    // MARK: - Assistant

    /// Assistant path: stream the LLM's answer into a fixed-size box, growing
    /// the text as tokens arrive, then settle the box to the final size.
    func runAssistant(
        on transcript: String,
        screenshot screenshotTask: Task<(mediaType: String, data: String)?, Never>? = nil
    ) async {
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            presenter.hideSoon(); return
        }
        let config = Settings.shared.assistantConfig
        let key = Settings.shared.apiKey(for: config.provider)

        // Continue the previous chat only if the user tapped "Continue" after the
        // last answer; otherwise this is a fresh conversation.
        let history = chat.beginRequest()

        // The screenshot was kicked off in parallel with transcription (see
        // stopRecording); by now it's usually already done — awaiting it here is
        // ~free instead of a serial ~200-500ms subprocess before the request.
        var images: [AssistantClient.ImageInput]? = nil
        if config.attachScreenshot {
            let shot: (mediaType: String, data: String)?
            if let screenshotTask {
                shot = await screenshotTask.value
            } else {
                // No pre-capture (e.g. setting flipped mid-flight) — capture now.
                shot = await Task.detached(priority: .userInitiated, operation: {
                    ScreenCapture.fullScreenBase64()
                }).value
            }
            if let shot {
                images = [AssistantClient.ImageInput(media_type: shot.mediaType, data: shot.data)]
            }
        }

        // Switch the overlay to the streaming answer box. When continuing, show
        // the prior turns above the new answer so it reads as one conversation.
        presenter.streaming(priorTurns: chat.priorTurns, question: question)

        var accumulated = ""
        var lastRender = Date.distantPast
        do {
            for try await delta in app.assistant.askStream(
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
                    presenter.updateStreaming(accumulated)
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
    @MainActor private func finalizeAssist(question: String, answer: String) {
        endDictationActivityIfIdle()
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            chat.dropPending(); presenter.hideSoon(); return
        }
        HistoryStore.shared.add(trimmed)
        chat.answered(question: question, answer: trimmed)
        presenter.answer(trimmed)
    }

    /// Show an assistant failure (no Continue footer) and collapse soon.
    @MainActor private func showAssistantError(_ text: String) {
        chat.dropPending()
        presenter.result(text, isError: true, collapseAfter: 6.0)
    }

    /// User tapped "Continue": stash this turn into the conversation and hide the
    /// box (keeping chat state) so the next assistant keybind continues it.
    func continueChat() {
        chat.continueChat()
        presenter.dismiss()   // hide() resets the model (chat state lives here, untouched)
    }

    /// Shown when the backend couldn't be brought up in time — a clear message
    /// instead of an empty result.
    func showBackendError() {
        endDictationActivityIfIdle()
        // A spawn that can't start says what to fix — retrying never helps it.
        let msg = backend.lastSpawnError ?? "Starting up. Try again shortly."
        presenter.result(msg, collapseAfter: 3.5)
    }
}
