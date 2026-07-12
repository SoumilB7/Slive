import SwiftUI

/// A small, quiet pill that sits just above the bottom edge and shows a live
/// waveform only while you're actually recording. No halo, no timer, no
/// confirmation — it simply appears while you hold and fades when you release.
struct OverlayView: View {
    @ObservedObject var model: AudioModel

    private var visible: Bool { model.phase == .listening }

    var body: some View {
        pill
            .scaleEffect(visible ? 1 : 0.9)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)
            .frame(width: 240, height: 64)              // container (shadow spill)
            .animation(.spring(response: 0.30, dampingFraction: 0.82), value: model.phase)
            .allowsHitTesting(false)
    }

    private var pill: some View {
        WaveformView(levels: model.levels)
            .frame(width: 148, height: 20)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(Color.black.opacity(0.22))
                }
            }
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
    }
}
