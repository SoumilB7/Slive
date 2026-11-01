import Foundation

/// Rolling "seconds to decode a typical dictation", per model, persisted —
/// the speed graph shows THIS machine's measured numbers instead of the
/// static family guesses once a few dictations exist.
///
/// Measured ONLY by the `SpeechDecoder`'s sample path (the model is already
/// resident there, so model-load time can never leak in — the bug that once
/// put "~15s" on the graph), and only from clips in the calibration band:
/// long enough that fixed per-window overhead doesn't dominate, short
/// enough to be one Whisper window like a real dictation.
final class DecodeMetricsStore {
    static let standard = DecodeMetricsStore(store: UserDefaults.standard)

    private static let typicalDecodeKey = "typicalDecodeSeconds"
    private let store: KeyValueStore

    init(store: KeyValueStore) { self.store = store }

    /// Clips this long are honest one-window "typical dictation" samples.
    static func acceptableCalibrationClip(_ audioSeconds: Double) -> Bool {
        (3...30).contains(audioSeconds)
    }

    /// EMA blend: measurements settle fast but one outlier can't lie.
    static func blendedRate(old: Double?, new: Double) -> Double {
        old.map { $0 * 0.7 + new * 0.3 } ?? new
    }

    func typicalDecode(for model: String) -> Double? {
        values[model]
    }

    func record(model: String, audioSeconds: Double, decodeSeconds: Double) {
        guard Self.acceptableCalibrationClip(audioSeconds),
              decodeSeconds > 0, decodeSeconds < 30 else { return }
        var values = self.values
        values[model] = Self.blendedRate(old: values[model], new: decodeSeconds)
        store.set(values, forKey: Self.typicalDecodeKey)
    }

    private var values: [String: Double] {
        (store.object(forKey: Self.typicalDecodeKey) as? [String: Double]) ?? [:]
    }
}
