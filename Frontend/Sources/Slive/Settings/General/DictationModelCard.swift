import SwiftUI

/// The dictation (hold-to-talk) transcription model.
struct DictationModelCard: View {
    @ObservedObject var settings: Settings
    let transcription: TranscriptionModel

    var body: some View {
        ModelPickerCard(
            title: "MODEL",
            model: $settings.whisperModel,
            transcription: transcription,
            help: "Runs on this Mac",
            use: .dictation,
            suggestBalanced: true
        )
    }
}
