import AppKit
import SwiftUI

/// Finds SwiftUI's root NSScrollView without creating a second scrolling
/// region. The weak reference is refreshed whenever SwiftUI rebuilds the host.
struct SettingsScrollResolver: NSViewRepresentable {
    let resolve: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { resolveFrom(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { resolveFrom(view) }
    }

    private func resolveFrom(_ view: NSView) {
        if let scrollView = view.enclosingScrollView {
            resolve(scrollView)
        }
    }
}

/// Keeps pagination feeling like replacing the current sheet of rows instead
/// of teleporting through one giant document. AppKit is used here because the
/// project targets macOS 14, before SwiftUI exposed scroll geometry.
final class SettingsScrollKeeper: ObservableObject {
    weak var scrollView: NSScrollView?

    func applyPreservingBottomDistance(_ change: @escaping () -> Void) {
        guard let scrollView,
              let documentView = scrollView.documentView else {
            change()
            return
        }

        let viewportHeight = scrollView.contentView.bounds.height
        let oldMaximum = max(0, documentView.bounds.height - viewportHeight)
        let oldOffset = min(max(0, scrollView.contentView.bounds.origin.y), oldMaximum)
        let distanceFromBottom = oldMaximum - oldOffset

        change()

        // First hop lets @State replace the page; the second lets SwiftUI lay
        // out rows whose wrapped text can give the new page a different height.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                guard let scrollView = self?.scrollView,
                      let documentView = scrollView.documentView else { return }
                let newMaximum = max(
                    0, documentView.bounds.height - scrollView.contentView.bounds.height)
                let newOffset = max(0, newMaximum - distanceFromBottom)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: newOffset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}
