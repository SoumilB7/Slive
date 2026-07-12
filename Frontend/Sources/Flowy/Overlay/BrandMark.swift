import SwiftUI

/// Flowy's logo, drawn in code so it stays crisp at any size and matches the
/// overlay's palette: a gradient squircle with a white waveform.
struct BrandMark: View {
    var size: CGFloat = 64

    private let heights: [CGFloat] = [0.30, 0.55, 0.85, 1.0, 0.7, 0.9, 0.45, 0.6]

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: 0.56, saturation: 0.82, brightness: 1.0),
                        Color(hue: 0.48, saturation: 0.72, brightness: 0.95)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(waveform)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size * 0.01))
            )
            .frame(width: size, height: size)
            .shadow(color: Color(hue: 0.50, saturation: 0.6, brightness: 0.7).opacity(0.45),
                    radius: size * 0.16, y: size * 0.06)
    }

    private var waveform: some View {
        HStack(spacing: size * 0.045) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.95))
                    .frame(width: size * 0.06, height: size * 0.52 * heights[i])
            }
        }
        .shadow(color: .white.opacity(0.4), radius: size * 0.03)
    }
}
