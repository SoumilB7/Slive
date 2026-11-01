import SwiftUI

/// The latency ⇄ resources tradeoff, as a clickable graph: pick the
/// latency you want, see what it spends.
struct SpeedCard: View {
    let settings: Settings
    let transcription: TranscriptionModel

    var body: some View {
        SettingsCard("SPEED") {
            LatencyGraphView(settings: settings, transcription: transcription)
                .help("Lower latency keeps more in memory")
        }
    }
}
