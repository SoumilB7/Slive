/// The WhisperKit models Slive offers. An id is WhisperKit's variant name
/// (its download folder is `openai_whisper-<id>`). Adding one = one entry.
enum WhisperCatalog {
    static let tiny = "tiny.en"
    static let base = "base.en"
    static let turbo = "large-v3-v20240930_626MB"
    static let large = "large-v3"

    static let models: [ModelDescriptor] = [
        .init(id: tiny, engine: .whisper, label: "Whisper – tiny.en", note: "Fastest", size: "75 MB",
              bundled: true),
        .init(id: base, engine: .whisper, label: "Whisper – base.en", note: "Fast", size: "150 MB"),
        .init(id: turbo, engine: .whisper, label: "Whisper – large-v3 turbo", note: "Recommended", size: "600 MB"),
        .init(id: large, engine: .whisper, label: "Whisper – large-v3", note: "Most accurate", size: "1.5 GB"),
    ]
}
