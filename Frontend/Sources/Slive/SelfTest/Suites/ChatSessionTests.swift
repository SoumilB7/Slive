import Foundation

/// Assistant chat turns: continue only after "Continue", fresh otherwise.
@MainActor
enum ChatSessionTests {
    static let suite = TestSuite(name: "Chat session") { t in
        print("[Chat session]")
        var chat = ChatSession()
        t.check(chat.beginRequest() == nil, "a first request sends no history")

        chat.answered(question: "q1", answer: "a1")
        t.check(chat.beginRequest() == nil, "without Continue the next request starts fresh")

        chat.answered(question: "q1", answer: "a1")
        chat.continueChat()
        let history = chat.beginRequest() ?? []
        t.equal(history.map(\.role), ["user", "assistant"], "Continue sends the last turn as history")
        t.equal(history.map(\.content), ["q1", "a1"], "with its question and answer")
        t.equal(chat.priorTurns.map(\.text), ["q1", "a1"], "the overlay shows it above the new answer")

        chat.answered(question: "q2", answer: "a2")
        chat.continueChat()
        t.equal(chat.beginRequest()?.count, 4, "continuing again keeps the whole chat")

        chat.answered(question: "q3", answer: "a3")
        chat.dropPending()   // that answer failed
        chat.continueChat()
        t.equal(chat.beginRequest()?.count, 4, "a failed answer adds nothing to the chat")

        chat.answered(question: "q4", answer: "a4")
        chat.continueChat()
        chat.end()
        t.check(chat.beginRequest() == nil && chat.pendingTurn == nil, "✕ ends the chat")
    }
}
