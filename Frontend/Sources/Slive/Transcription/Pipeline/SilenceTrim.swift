/// Trim leading and trailing silence from a canonical 16 kHz mono buffer
/// before decoding. Dead air costs decode windows and trips fallback
/// thresholds for nothing — every one-shot dictation runs through this
/// first. Pure function, covered by `--self-test`.
///
/// Two thresholds, because one fixed level ate the ends of sentences:
/// - **Is there speech at all?** Some frame must exceed `speechGate`
///   (0.01 RMS); otherwise the hold was silence → empty slice.
/// - **Where does it start and end?** Measured against the clip's OWN
///   noise floor (10th-percentile frame RMS × 4, clamped 0.003…0.01).
///   Voices trail off at the end of a sentence to ~0.003–0.009 RMS —
///   still several times the room noise, but under the old fixed 0.01
///   cut, so the last words were deleted before Whisper saw them (Sep
///   2026 audit: ~85 of 1485 captured clips, confirmed by re-decoding).
struct SilenceTrim: AudioStage {
    /// A hold counts as speech only if some 10ms frame is louder than this —
    /// below it the whole clip is treated as silence and the decode skipped.
    static let speechGate: Float = 0.01
    /// Bounds for the per-clip edge threshold (see `trim`).
    static let edgeFloor: Float = 0.003
    /// Edge threshold = this × the clip's own noise floor, clamped to
    /// [`edgeFloor`, `speechGate`].
    static let noiseMultiple: Float = 4
    /// Kept before the first voiced frame (150ms) and after the last (300ms).
    static let leadPad = 2_400
    static let tailPad = 4_800

    func apply(_ samples: [Float]) -> ArraySlice<Float> { Self.trim(samples) }

    static func trim(_ samples: [Float]) -> ArraySlice<Float> {
        let frame = 160   // 10ms at 16k
        let frames = samples.count / frame
        guard frames > 0 else { return samples[0..<0] }

        var rms = [Float](repeating: 0, count: frames)
        var loudest: Float = 0
        for f in 0..<frames {
            var sum: Float = 0
            for j in (f * frame)..<(f * frame + frame) { sum += samples[j] * samples[j] }
            rms[f] = (sum / Float(frame)).squareRoot()
            loudest = max(loudest, rms[f])
        }
        guard loudest > speechGate else { return samples[0..<0] }

        let threshold = edgeThreshold(frameRMS: rms)
        // The END edge uses the gentler "true silence" line: anything above
        // max(1.5 × room floor, ½ threshold) is still voice. In a noisy room
        // the edge threshold clamps at 0.01 and soft final words (0.005–0.01)
        // were cut — Oct 8: "…see this in a change [as well]". Replayed on 150
        // recent clips with the real model: 143 identical, 5 endings
        // recovered, 0 invented words.
        let tailThreshold = max(1.5 * noiseFloor(frameRMS: rms), 0.5 * threshold)
        guard let first = rms.firstIndex(where: { $0 > threshold }),
              let last = rms.lastIndex(where: { $0 > min(threshold, tailThreshold) }) else { return samples[0..<0] }
        let start = max(0, first * frame - leadPad)
        let end = min(samples.count, (last + 1) * frame + tailPad)
        return samples[start..<end]
    }

    /// The per-clip edge threshold: `noiseMultiple` × the 10th-percentile
    /// frame RMS (the room's noise floor), clamped to
    /// [`edgeFloor`, `speechGate`]. A clip that is mostly speech
    /// reads a high floor and clamps to the old 0.01 — never stricter.
    static func edgeThreshold(frameRMS: [Float]) -> Float {
        guard !frameRMS.isEmpty else { return speechGate }
        return min(speechGate, max(edgeFloor, noiseMultiple * noiseFloor(frameRMS: frameRMS)))
    }

    /// The room's noise floor: the clip's 10th-percentile 10ms frame RMS.
    static func noiseFloor(frameRMS: [Float]) -> Float {
        guard !frameRMS.isEmpty else { return 0 }
        let sorted = frameRMS.sorted()
        return sorted[min(sorted.count - 1, sorted.count / 10)]
    }
}
