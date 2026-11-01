import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport
import SliveTestKit

/// Mic format revalidation + history sequencing
@MainActor
enum CaptureAndHistoryTests {
    static let suite = TestSuite(name: "Mic format / history") { t in
        print("[Mic format / history]")
        // A kept mic unit is rebuilt only when the live hardware differs.
        let mono48 = MicCapture.HardwareShape(sampleRate: 48_000, channels: 1)
        t.check(!MicCapture.needsRebuild(built: mono48, current: mono48), "same shape keeps the unit")
        t.check(MicCapture.needsRebuild(
                built: mono48, current: .init(sampleRate: 24_000, channels: 1)),
              "sample-rate switch between holds rebuilds")
        t.check(MicCapture.needsRebuild(
                built: mono48, current: .init(sampleRate: 48_000, channels: 2)),
              "channel-count change rebuilds")
        t.check(!MicCapture.needsRebuild(built: mono48, current: nil),
              "unreadable device keeps the unit (start-failure path handles it)")
        t.check(MicCapture.needsRebuild(built: nil, current: mono48), "unknown built shape rebuilds")

        // A blocked/dead mic hands back pure zeros → "No sound", not a fade.
        t.check(AudioRecorder.isDigitalSilence([Float](repeating: 0, count: 8_000)),
              "all-zero hold reads as no mic signal")
        let roomTone = (0..<8_000).map { Float(sin(Double($0) * 0.7)) * 3e-4 }
        t.check(!AudioRecorder.isDigitalSilence(roomTone),
              "a quiet room's noise floor is not 'no sound'")
        t.check(!AudioRecorder.isDigitalSilence([]),
              "no canonical samples (native-format path) never claims silence")

        // Bounds: TTL first, then the count cap keeps the newest.
        let now = Date()
        var list = (0..<(HistoryStore.maxEntries + 5)).map {
            HistoryEntry(id: UUID(), text: "e\($0)", createdAt: now.addingTimeInterval(-Double($0)))
        }
        list.append(HistoryEntry(id: UUID(), text: "old",
                                 createdAt: now.addingTimeInterval(-HistoryStore.ttl - 1)))
        HistoryStore.applyBounds(&list, now: now)
        t.check(list.count == HistoryStore.maxEntries && list.first?.text == "e0"
                && !list.contains { $0.text == "old" },
              "bounds drop expired + cap at max, newest kept")

        // Back-to-back mutations must build on each other, not on the
        // main-thread mirror (which can't update while we block here).
        let store = HistoryStore(fileURL: nil)
        store.add("first")
        store.add("second")
        store.add("   ")   // whitespace-only is ignored
        let two = store.syncedEntries()
        t.equal(two.map(\.text), ["second", "first"], "back-to-back adds both survive, newest first")
        if let firstID = two.last?.id {
            store.remove(firstID)
            store.add("third")
            t.equal(store.syncedEntries().map(\.text), ["third", "second"],
                  "remove then add sequence on the source of truth")
        }
        store.add(String(repeating: "x", count: HistoryStore.maxTextLength + 50))
        t.equal(store.syncedEntries().first?.text.count, HistoryStore.maxTextLength,
              "entry text capped")
        store.clearAll()
        t.check(store.syncedEntries().isEmpty, "clearAll empties the store")

        // Unreadable history is moved aside next to the original, not overwritten.
        let url = URL(fileURLWithPath: "/Slive/history.json")
        t.equal(HistoryStore.corruptBackupURL(for: url, at: Date(timeIntervalSince1970: 1_700_000_000)).path,
              "/Slive/history.json.corrupt-1700000000", "corrupt file backup name")
        // The sweep reads the set-aside time back from that name, and only
        // ever matches this file's backups.
        t.equal(HistoryStore.corruptBackupDate(name: "history.json.corrupt-1700000000", for: url),
              Date(timeIntervalSince1970: 1_700_000_000), "backup date parses from its name")
        t.check(HistoryStore.corruptBackupDate(name: "history.json", for: url) == nil
                && HistoryStore.corruptBackupDate(name: "other.json.corrupt-1700000000", for: url) == nil
                && HistoryStore.corruptBackupDate(name: "history.json.corrupt-x", for: url) == nil,
              "sweep ignores everything but this file's backups")

        // Settings fallbacks match fresh-install defaults.
        if let empty = try? JSONDecoder().decode(AssistantConfig.self, from: Data("{}".utf8)) {
            t.equal(empty, AssistantConfig.default, "assistant config: missing fields fall back to .default")
        } else {
            t.check(false, "assistant config: missing fields fall back to .default", "decode threw")
        }
        t.equal(Settings.localMemDefaultGB(ramGB: 8), 4, "8 GB Mac: memory limit default fits")
        t.equal(Settings.localMemDefaultGB(ramGB: 32), 9, "big Mac: memory limit default stays 9 GB")
        t.equal(Settings.localMemMaxGB(ramGB: 8), 6, "8 GB Mac: slider leaves 2 GB for macOS")
        t.equal(Settings.localMemMaxGB(ramGB: 64), 12, "big Mac: slider caps at 12 GB")
        t.check(Settings.localMemDefaultGB(ramGB: 8) <= Settings.localMemMaxGB(ramGB: 8),
              "default sits inside the slider")
    }
}
