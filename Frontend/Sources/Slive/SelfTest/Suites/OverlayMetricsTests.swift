import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

/// Overlay geometry
@MainActor
enum OverlayMetricsTests {
    static let suite = TestSuite(name: "Overlay geometry") { t in
        print("[Overlay geometry]")
        let short = OverlayMetrics.panelSize(for: "hi")
        let long = OverlayMetrics.panelSize(
            for: String(repeating: "a fairly long sentence about nothing. ", count: 8))
        t.check(long.height > short.height, "panel grows with text")
        t.check(long.width >= short.width, "panel width never shrinks with more text")

        var boundsOK = true
        for text in ["", "x", String(repeating: "word ", count: 500)] {
            let p = OverlayMetrics.panelSize(for: text)
            if p.width <= 0 || p.height <= 0 || p.height >= 2000 { boundsOK = false }
        }
        t.check(boundsOK, "panel sizes positive and bounded")

        let base = OverlayMetrics.panelSize(for: "answer")
        let assistant = OverlayMetrics.assistantPanelSize(for: "answer")
        t.check(assistant.height == base.height + OverlayMetrics.continueFooterHeight
                && assistant.width == base.width,
              "assistant panel adds exactly the Continue footer")
        t.check(OverlayMetrics.assistantStreamingPanelSize.height
                == OverlayMetrics.streamingPanelSize.height + OverlayMetrics.continueFooterHeight,
              "streaming assistant panel adds exactly the Continue footer")

        // The copy box's "why" line gets its own room, never squeezing the text.
        let plain = OverlayMetrics.panelSize(for: "hi")
        let noted = OverlayMetrics.panelSize(for: "hi", note: "Not typed · Accessibility is off")
        t.check(noted.height > plain.height && noted.width > plain.width,
              "a note line widens and heightens the copy box")
        t.check(OverlayMetrics.panelSize(for: "hi", note: nil) == plain,
              "no note → same box as before")
    }
}
