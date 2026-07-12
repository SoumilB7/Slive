import SwiftUI

/// A tiny, quiet black pill that sits just above the bottom edge and shows a
/// live waveform only while recording. Roughly a third the previous size.
struct OverlayView: View {
    @ObservedObject var model: AudioModel

    private var visible: Bool { model.phase == .listening }

    var body: some View {
        pill
            .scaleEffect(visible ? 1 : 0.9)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 4)
            .frame(width: 180, height: 56)              // container (shadow spill)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: model.phase)
            .allowsHitTesting(false)
    }

    private var pill: some View {
        WaveformView(levels: model.levels)
            .frame(width: 70, height: 26)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.92)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.40), radius: 6, y: 2)
    }
}
