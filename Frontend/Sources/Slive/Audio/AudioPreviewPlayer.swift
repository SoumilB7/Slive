import AVFoundation
import Foundation

/// Playback for captured training audio with real controls: play/pause, a
/// scrubbable position, and elapsed/total time. One clip plays at a time —
/// starting another row's clip takes over the player.
@MainActor
final class AudioPreviewPlayer: NSObject, ObservableObject {
    static let shared = AudioPreviewPlayer()

    /// The sample id whose clip is loaded (nil = idle).
    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// Play this clip; if it's already current, toggle play/pause instead.
    func toggle(id: String, url: URL) {
        if currentID == id, player != nil {
            isPlaying ? pause() : resume()
            return
        }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        player = p
        currentID = id
        duration = p.duration
        position = 0
        resume()
    }

    /// Jump to a position (seconds). Works while playing or paused.
    func seek(to t: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = min(max(0, t), duration)
        position = p.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        currentID = nil
        isPlaying = false
        position = 0
        duration = 0
        stopTicker()
    }

    private func resume() {
        // Replay from the top if the clip already finished.
        if let p = player, !p.isPlaying, position >= duration - 0.05 {
            p.currentTime = 0
            position = 0
        }
        player?.play()
        isPlaying = true
        startTicker()
    }

    private func pause() {
        player?.pause()
        position = player?.currentTime ?? position
        isPlaying = false
        stopTicker()
    }

    private func finished() {
        isPlaying = false
        position = duration
        stopTicker()
    }

    // MARK: - Position updates (only while playing)

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, self.isPlaying else { return }
                self.position = p.currentTime
            }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// mm:ss for the readout.
    static func timeText(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension AudioPreviewPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }
}
