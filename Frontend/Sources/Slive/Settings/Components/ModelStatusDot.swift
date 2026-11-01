import SwiftUI

/// 7pt dot beside the brand lockup reflecting the active dictation model:
/// green = ready, pulsing accent = downloading/preparing, orange = failed,
/// faint = not downloaded.
struct WhisperStatusDot: View {
    @ObservedObject var settings: Settings
    @ObservedObject var transcription: TranscriptionModel

    var body: some View {
        switch transcription.status(for: settings.whisperModel) {
        case .ready:
            StatusDot(color: SliveTheme.ok, size: 7).help("\(settings.whisperModel) ready")
        case .downloading, .preparing:
            StatusDot(color: SliveTheme.accent, pulses: true, size: 7)
                .help("\(settings.whisperModel) loading")
        case .failed:
            StatusDot(color: SliveTheme.warn, size: 7).help("Model failed to load")
        case .notDownloaded:
            StatusDot(color: SliveTheme.textGhost, size: 7)
                .help("\(settings.whisperModel) not downloaded")
        }
    }
}
