import Foundation

/// The in-memory assistant conversation (never persisted). A chat continues
/// only when the user taps "Continue" under an answer; the next assistant
/// call then sends the earlier turns as history. Anything else starts fresh.
struct ChatSession {
    private(set) var conversation: [AssistantClient.HistoryItem] = []
    /// Set only by tapping "Continue"; consumed by the next request.
    private(set) var chatActive = false
    /// The last answered turn — joins the conversation if Continue is tapped.
    private(set) var pendingTurn: (question: String, answer: String)?

    /// A new assistant request: continue the previous chat only if the user
    /// tapped "Continue" after the last answer; otherwise this is a fresh
    /// conversation. Returns the history to send (nil = none).
    mutating func beginRequest() -> [AssistantClient.HistoryItem]? {
        let continuing = chatActive
        chatActive = false
        if !continuing { conversation.removeAll() }
        return conversation.isEmpty ? nil : conversation
    }

    /// The earlier turns, as the overlay shows them above the new answer.
    var priorTurns: [ChatTurn] {
        conversation.map { ChatTurn(role: $0.role, text: $0.content) }
    }

    /// An answer arrived — remembered for a possible continuation.
    mutating func answered(question: String, answer: String) {
        pendingTurn = (question, answer)
    }

    /// No answer to continue from (empty, or failed).
    mutating func dropPending() {
        pendingTurn = nil
    }

    /// User tapped "Continue": stash this turn into the conversation so the
    /// next assistant keybind continues it.
    mutating func continueChat() {
        if let t = pendingTurn {
            conversation.append(AssistantClient.HistoryItem(role: "user", content: t.question))
            conversation.append(AssistantClient.HistoryItem(role: "assistant", content: t.answer))
        }
        pendingTurn = nil
        chatActive = true
    }

    /// ✕: the chat is over.
    mutating func end() {
        chatActive = false
        conversation.removeAll()
        pendingTurn = nil
    }
}
