/// A step on the 16 kHz mono samples before the decode.
protocol AudioStage: Sendable {
    var name: String { get }
    func apply(_ samples: [Float]) -> ArraySlice<Float>
}

/// A step on the decoded text.
protocol TextStage: Sendable {
    var name: String { get }
    func apply(_ text: String) -> String
}

extension AudioStage { var name: String { String(describing: Self.self) } }
extension TextStage { var name: String { String(describing: Self.self) } }

/// What happens around a decode, in order: audio stages → decode → cleanup
/// (engine artifacts) → corrections (user-facing rewrites). The app's
/// dictation path, continuous dictation, ground-truth labeling and the dev
/// benches all run their text through one of these, so a stage added here
/// lands everywhere at once.
///
/// Cleanup and corrections are separate phases because continuous
/// dictation stitches the streamed prefix to the release decode between
/// them: a vocabulary term split across that seam must still match.
struct DictationPipeline: Sendable {
    var audio: [any AudioStage]
    var cleanup: [any TextStage]
    var corrections: [any TextStage]

    /// trim → decode → clean → vocabulary. One-shot dictation (hold-to-talk).
    static func standard(vocabulary: String) -> DictationPipeline {
        DictationPipeline(audio: [SilenceTrim()],
                          cleanup: [StreamHygiene()],
                          corrections: [VocabularyCorrection(hotwords: vocabulary)])
    }

    /// Continuous dictation: the standard stages, plus the leading-space
    /// strip a field being typed into live needs.
    static func live(vocabulary: String) -> DictationPipeline {
        var pipeline = standard(vocabulary: vocabulary)
        pipeline.cleanup.append(LeadingSpaceStrip())
        return pipeline
    }

    /// The samples to decode. One stage returns its slice of `samples` as is
    /// (no copy); a later stage works on a copy of the previous result.
    func prepare(_ samples: [Float]) -> ArraySlice<Float> {
        var out = samples[...]
        for (i, stage) in audio.enumerated() {
            out = stage.apply(i == 0 ? samples : Array(out))
        }
        return out
    }

    /// Decoded text with engine artifacts removed.
    func clean(_ text: String) -> String {
        cleanup.reduce(text) { $1.apply($0) }
    }

    /// Clean text with the user's rewrites applied.
    func correct(_ text: String) -> String {
        corrections.reduce(text) { $1.apply($0) }
    }

    /// Decoded text → what's typed: cleanup, then corrections.
    func finish(_ text: String) -> String { correct(clean(text)) }

    /// Stage names in run order, the decode marked as "decode".
    var order: [String] {
        audio.map(\.name) + ["decode"] + cleanup.map(\.name) + corrections.map(\.name)
    }
}
