import AppKit
import SwiftUI

/// A small picture of the screen that is also the control: the pill sits
/// where it will on screen, at the overlay opacity; click the other spot to
/// move it there. Shaped like the main display. Text (results, the copy box,
/// "Loading model…") always appears at the bottom whichever spot is chosen.
struct PillPositionPicker: View {
    @ObservedObject var settings: Settings

    private static let height: CGFloat = 96

    /// The main display's shape, so the preview reads as "your screen".
    private var aspect: CGFloat {
        guard let frame = NSScreen.main?.frame, frame.height > 0 else { return 1.6 }
        return frame.width / frame.height
    }

    var body: some View {
        ZStack {
            // Muted wallpaper with a slim menu bar.
            LinearGradient(
                colors: [Color(red: 0.23, green: 0.28, blue: 0.28),
                         Color(red: 0.20, green: 0.23, blue: 0.27),
                         Color(red: 0.24, green: 0.22, blue: 0.28)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                Rectangle().fill(SliveTheme.wellFill).frame(height: 5)
                Spacer(minLength: 0)
            }
            spot(right: false)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 1)
            spot(right: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 1)
                .padding(.top, 5)
        }
        .frame(width: Self.height * aspect, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: SliveTheme.miniRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SliveTheme.miniRadius, style: .continuous)
                .strokeBorder(SliveTheme.frameStroke, lineWidth: 0.8)
        )
        .help("Click to move · text stays at the bottom")
    }

    /// One position: the live pill when chosen, a quiet outline otherwise.
    private func spot(right: Bool) -> some View {
        let chosen = settings.pillOnRight == right
        return SpotButton(upright: right, chosen: chosen, opacity: settings.overlayOpacity) {
            settings.pillOnRight = right
        }
        .accessibilityLabel("Pill position, \(right ? "Right" : "Bottom")")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

private struct SpotButton: View {
    let upright: Bool
    let chosen: Bool
    let opacity: Double
    let action: () -> Void

    @State private var hovering = false

    /// The drawn pill, at roughly the real pill's proportions.
    private var pill: CGSize { upright ? CGSize(width: 11, height: 27) : CGSize(width: 30, height: 11) }
    /// Click area — never below 24 pt across.
    private var hit: CGSize { upright ? CGSize(width: 24, height: 44) : CGSize(width: 48, height: 24) }

    var body: some View {
        Button(action: action) {
            ZStack {
                if chosen {
                    Capsule().fill(.black)
                        .overlay(waveform)
                        .opacity(max(opacity, 0.35))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                } else {
                    Capsule()
                        .fill(hovering ? SliveTheme.wellFill : Color.clear)
                        .overlay(Capsule().strokeBorder(hovering ? SliveTheme.textSecondary : SliveTheme.pillRing, lineWidth: 1))
                }
            }
            .frame(width: pill.width, height: pill.height)
            .frame(width: hit.width, height: hit.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(chosen)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: chosen)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Five tiny bars, laid along the pill.
    private var waveform: some View {
        let lengths: [CGFloat] = [3, 5.4, 7, 5.4, 3]
        let layout = upright ? AnyLayout(VStackLayout(spacing: 1.2)) : AnyLayout(HStackLayout(spacing: 1.2))
        return layout {
            ForEach(lengths.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: SliveTheme.tickRadius)
                    .fill(.white)
                    .frame(width: upright ? lengths[i] : 1.2, height: upright ? 1.2 : lengths[i])
            }
        }
    }
}
