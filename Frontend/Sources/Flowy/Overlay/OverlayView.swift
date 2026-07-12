import SwiftUI

/// The floating pill. Reacts to `AudioModel.phase`: a live waveform while you
/// hold the key, a brief "Saving…", then a "Saved · 0:07" confirmation before
/// it springs away.
struct OverlayView: View {
    @ObservedObject var model: AudioModel

    private let accent = Color(hue: 0.76, saturation: 0.7, brightness: 1.0)

    var body: some View {
        ZStack {
            halo
            pill
                .scaleEffect(visible ? 1 : 0.82)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 10)
        }
        .frame(width: 360, height: 120)
        .animation(.spring(response: 0.36, dampingFraction: 0.72), value: model.phase)
        .allowsHitTesting(false)
    }

    private var visible: Bool { model.phase != .idle }

    // MARK: - Halo

    private var halo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [accent.opacity(0.55), accent.opacity(0.0)],
                    center: .center, startRadius: 2, endRadius: 150
                )
            )
            .frame(width: 300, height: 300)
            .scaleEffect(0.55 + 0.55 * CGFloat(model.glow))
            .opacity(isListening ? Double(0.18 + 0.6 * model.glow) : 0)
            .blur(radius: 24)
            .animation(.easeOut(duration: 0.12), value: model.glow)
    }

    // MARK: - Pill

    private var pill: some View {
        HStack(spacing: 12) {
            leadingGlyph
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 18)
        .frame(width: 288, height: 60)
        .background(pillBackground)
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        )
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
        .shadow(color: accent.opacity(isListening ? 0.35 : 0), radius: 26, y: 0)
    }

    private var pillBackground: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color.black.opacity(0.42))
            Capsule().fill(
                LinearGradient(
                    colors: [.white.opacity(0.10), .clear],
                    startPoint: .top, endPoint: .center
                )
            )
        }
    }

    // MARK: - Leading glyph

    @ViewBuilder
    private var leadingGlyph: some View {
        switch model.phase {
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(hue: 0.38, saturation: 0.7, brightness: 0.95))
                .font(.system(size: 20, weight: .semibold))
                .transition(.scale.combined(with: .opacity))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(hue: 0.08, saturation: 0.85, brightness: 1.0))
                .font(.system(size: 18, weight: .semibold))
        case .tooShort:
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(.white.opacity(0.7))
                .font(.system(size: 17, weight: .medium))
        default:
            Image(systemName: "mic.fill")
                .foregroundStyle(accent)
                .font(.system(size: 18, weight: .semibold))
                .scaleEffect(1 + 0.16 * CGFloat(model.glow))
                .shadow(color: accent.opacity(0.8), radius: 6 * CGFloat(model.glow))
        }
    }

    // MARK: - Center content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening, .saving:
            WaveformView(levels: model.levels)
                .frame(height: 34)
        case .saved:
            Text("Saved")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        case .tooShort:
            Text("Hold fn to talk")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        case .error(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailing: some View {
        switch model.phase {
        case .listening:
            Text(timeString(model.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.numericText())
        case .saving:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
        case .saved(let seconds):
            Text(timeString(seconds))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        default:
            EmptyView()
        }
    }

    private var isListening: Bool {
        model.phase == .listening
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
