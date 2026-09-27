import AVFoundation
import Foundation

/// Shared plumbing for the dev benchmarks (`--bench-*`): captured training
/// clips, WAV reading, word error rate. Dev tooling only.
@MainActor
enum BenchSupport {
    struct Clip { let id: String; let url: URL; let reference: String?; var order = 0 }

    /// Newest-first; stratified across lengths unless `since` is given
    /// (then simply the newest clips on/after that date).
    static func loadClips(minSeconds: Double, limit: Int, labeledOnly: Bool = false,
                          since: String? = nil) -> [Clip] {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Slive/training")
        guard let text = try? String(contentsOf: dir.appendingPathComponent("samples.jsonl"),
                                     encoding: .utf8) else { return [] }
        var buckets: [[Clip]] = [[], [], [], []]
        var order = 0
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String, let rel = obj["audioFile"] as? String else { continue }
            if let since, ((obj["createdAt"] as? String) ?? "") < since { continue }
            let url = dir.appendingPathComponent(rel)
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            guard seconds >= minSeconds else { continue }
            let final = (obj["finalText"] as? String) ?? ""
            let reference = final.isEmpty ? obj["llmTranscript"] as? String : final
            if labeledOnly, reference == nil { continue }
            buckets[seconds < 5 ? 0 : seconds < 15 ? 1 : seconds < 30 ? 2 : 3]
                .append(Clip(id: id, url: url, reference: reference, order: order))
            order += 1
        }
        if since != nil { return buckets.flatMap { $0 }.sorted { $0.order < $1.order }.prefix(limit).map { $0 } }
        let share = [0.25, 0.35, 0.25, 0.15]
        return buckets.enumerated().flatMap { b, clips in clips.prefix(Int((Double(limit) * share[b]).rounded())) }
    }

    static func readWAV(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData, file.processingFormat.sampleRate == 16_000
        else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }

    /// The early text is missing words from the END of today's text: its
    /// last three words don't appear at today's end and today is longer.
    static func lostEnding(early: String, today: String) -> Bool {
        func words(_ s: String) -> [Substring] { s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") } }
        let e = words(early), t = words(today)
        guard t.count > e.count else { return false }
        return Array(e.suffix(3)) != Array(t.suffix(min(3, e.count)))
    }

    /// Word error rate of `hyp` against `ref` (lowercased, punctuation-free).
    static func wer(_ hyp: String, _ ref: String) -> Double {
        func words(_ s: String) -> [Substring] { s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") } }
        let h = words(hyp), r = words(ref)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + [Int](repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
