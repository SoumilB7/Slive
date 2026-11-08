import AppKit
import SliveTestKit

/// Where the overlay panel lands: every pill position × every overlay
/// state × the screen layouts people actually have (small and huge
/// displays, Dock on any side, a hidden menu bar, second displays with
/// negative origins) — through OverlayController's own placement rules.
@MainActor
enum OverlayPlacementTests {
    typealias Screen = OverlayController.ScreenGeometry

    /// A display: its frame, and the visible frame macOS leaves after the
    /// menu bar (notch-tall or hidden) and the Dock.
    static func screen(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                       menuBar: CGFloat = 37, dock: (edge: NSRectEdge, size: CGFloat)? = nil) -> Screen {
        let frame = CGRect(x: x, y: y, width: w, height: h)
        var visible = CGRect(x: x, y: y, width: w, height: h - menuBar)
        if let dock {
            switch dock.edge {
            case .minY: visible.origin.y += dock.size; visible.size.height -= dock.size
            case .minX: visible.origin.x += dock.size; visible.size.width -= dock.size
            case .maxX: visible.size.width -= dock.size
            default: break
            }
        }
        return Screen(frame: frame, visibleFrame: visible)
    }

    /// Display arrangements; the first screen is the main one.
    static let layouts: [(name: String, screens: [Screen])] = [
        ("13-inch notch, Dock below", [screen(0, 0, 1470, 956, dock: (.minY, 75))]),
        ("13-inch, menu bar and Dock hidden", [screen(0, 0, 1470, 956, menuBar: 0)]),
        ("13-inch, Larger Text", [screen(0, 0, 1024, 665, dock: (.minY, 60))]),
        ("older 13-inch", [screen(0, 0, 1280, 800, menuBar: 25, dock: (.minY, 70))]),
        ("Dock left", [screen(0, 0, 1470, 956, dock: (.minX, 80))]),
        ("Dock right", [screen(0, 0, 1470, 956, dock: (.maxX, 80))]),
        ("projector 800×600, big Dock", [screen(0, 0, 800, 600, menuBar: 25, dock: (.minY, 120))]),
        ("4K at 1×", [screen(0, 0, 3840, 2160, menuBar: 25)]),
        ("4K looks like 1080p", [screen(0, 0, 1920, 1080, menuBar: 25, dock: (.minY, 64))]),
        ("ultrawide", [screen(0, 0, 3440, 1440, menuBar: 25)]),
        ("super ultrawide", [screen(0, 0, 5120, 1440, menuBar: 25)]),
        ("portrait", [screen(0, 0, 1080, 1920, menuBar: 25)]),
        ("laptop + display to the left", [screen(0, 0, 1470, 956), screen(-1920, -124, 1920, 1080, menuBar: 25)]),
        ("laptop + display above", [screen(0, 0, 1470, 956), screen(-545, 956, 2560, 1440, menuBar: 25)]),
        ("laptop + display below", [screen(0, 0, 1470, 956), screen(200, -1080, 1920, 1080, menuBar: 0)]),
        ("display left-and-below, laptop main", [screen(0, 0, 1470, 956, dock: (.minY, 75)),
                                                 screen(-2560, -400, 2560, 1440, menuBar: 25)]),
        ("clamshell: external main, laptop right", [screen(0, 0, 2560, 1440, menuBar: 25),
                                                    screen(2560, 0, 1470, 956)]),
        ("three displays", [screen(0, 0, 1470, 956), screen(-1920, 0, 1920, 1080, menuBar: 25),
                            screen(1470, 300, 1080, 1920, menuBar: 25)]),
    ]

    /// One of each overlay state, long and empty text included. Built from
    /// `ListenKind.allCases`; `expectedInteractive` switches over every
    /// case, so a new state fails to compile until it is placed here.
    static var states: [(name: String, state: OverlayState)] {
        let long = String(repeating: "a long dictated sentence that keeps going ", count: 60)
        let history = (0..<12).map { ChatTurn(role: $0 % 2 == 0 ? "user" : "assistant", text: long) }
        var list: [(String, OverlayState)] = [("idle", .idle)]
        list += OverlayState.ListenKind.allCases.map { ("listening \($0)", .listening($0)) }
        list += [
            ("transcribing", .transcribing(stuck: false)),
            ("transcribing, stuck", .transcribing(stuck: true)),
            ("result", .result(OverlayResult(text: "Hello there."))),
            ("result, empty", .result(OverlayResult(text: ""))),
            ("result, long", .result(OverlayResult(text: long))),
            ("result, one unbroken word", .result(OverlayResult(text: String(repeating: "x", count: 4000)))),
            ("copy box with note", .result(OverlayResult(text: long, note: "Not typed · secure input is on"))),
            ("error", .result(OverlayResult(text: "The model failed to load. " + long, isError: true))),
            ("answer streaming", .result(OverlayResult(text: long, answer: .init(streaming: true)))),
            ("answer streaming, chat", .result(OverlayResult(text: long, answer: .init(streaming: true, priorTurns: history,
                                                                                         question: long)))),
            ("answer", .result(OverlayResult(text: "Short answer.", answer: .init(streaming: false)))),
            ("answer, long", .result(OverlayResult(text: long, answer: .init(streaming: false)))),
            ("answer, chat history", .result(OverlayResult(text: long, answer: .init(streaming: false, priorTurns: history,
                                                                                      question: long)))),
        ]
        return list
    }

    /// The clickability rule, per case: only boxes and a stuck pill's ✕.
    static func expectedInteractive(_ s: OverlayState) -> Bool {
        switch s {
        case .idle, .listening: return false
        case .transcribing(let stuck): return stuck
        case .result: return true
        }
    }

    static let suite = TestSuite(name: "Overlay placement") { t in
        print("[Overlay placement]")
        var sizes = Sweep(), onScreen = Sweep(), sameScreen = Sweep(), clicks = Sweep()
        var placements = 0
        for (name, state) in states {
            clicks.expect(state.isInteractive == expectedInteractive(state), "\(name)")
            clicks.expect(state.showsText == (state.result != nil), "\(name): text only in a box")
        }
        for (layout, screens) in layouts {
            for target in screens {
                // The mouse anywhere inside a display puts the overlay there.
                let f = target.frame
                let mice = [CGPoint(x: f.midX, y: f.midY), CGPoint(x: f.minX + 1, y: f.minY + 1),
                            CGPoint(x: f.maxX - 1, y: f.maxY - 1), CGPoint(x: f.minX, y: f.maxY)]
                for mouse in mice {
                    let picked = OverlayController.visibleFrame(mouse: mouse, screens: screens, main: screens.first)
                    sameScreen.expect(picked == target.visibleFrame, "\(layout): mouse \(mouse) → \(String(describing: picked))")
                }
                for pillOnRight in [false, true] {
                    for (name, state) in states {
                        let size = state.panelSize(pillOnRight: pillOnRight)
                        let origin = OverlayController.origin(size: size, in: target.visibleFrame,
                                                              pillOnRight: pillOnRight, showsText: state.showsText)
                        let frame = CGRect(origin: origin, size: size)
                        placements += 1
                        let finite = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
                        sizes.expect(finite && size.width > 0 && size.height > 0,
                                     "\(layout) \(name) right=\(pillOnRight): \(frame)")
                        onScreen.expect(target.visibleFrame.contains(frame),
                                        "\(layout) \(name) right=\(pillOnRight): \(frame) outside \(target.visibleFrame)")
                    }
                }
            }
            // The mouse off every display (between them, or mid-reconfigure)
            // still places on a real one: the main, else the first.
            let lost = CGPoint(x: 100_000, y: 100_000)
            sameScreen.expect(OverlayController.visibleFrame(mouse: lost, screens: screens, main: screens.first)
                              == screens.first?.visibleFrame, "\(layout): lost mouse → main")
            sameScreen.expect(OverlayController.visibleFrame(mouse: lost, screens: screens, main: nil)
                              == screens.first?.visibleFrame, "\(layout): no main → first")
        }
        t.check(OverlayController.visibleFrame(mouse: .zero, screens: [], main: nil) == nil,
                "no displays at all: no placement (the panel stays put)")
        sizes.report(&t, "every overlay size is finite and non-zero (\(placements) placements)")
        onScreen.report(&t, "every state, both pill positions, every layout: fully inside the visible frame")
        sameScreen.report(&t, "the overlay follows the mouse's display, with a fallback when it's on none")
        clicks.report(&t, "click-through except boxes and a stuck pill's ✕; text only in a box")

        // Text never follows the pill to the right edge; the pill alone does.
        let visible = layouts[0].screens[0].visibleFrame
        let right = OverlayController.origin(size: OverlayMetrics.pillSize(onRight: true), in: visible,
                                             pillOnRight: true, showsText: false)
        let box = OverlayState.result(OverlayResult(text: "hi"))
        let boxOrigin = OverlayController.origin(size: box.panelSize(pillOnRight: true), in: visible,
                                                 pillOnRight: true, showsText: true)
        t.check(right.x + OverlayMetrics.pillSize(onRight: true).width == visible.maxX - 2
                && abs(boxOrigin.x + box.panelSize(pillOnRight: true).width / 2 - visible.midX) < 0.5,
                "the right-edge pill hugs the edge; its box still shows bottom-centre")
        t.check(OverlayMetrics.pillSize(onRight: true).height > OverlayMetrics.pillSize(onRight: true).width
                && OverlayMetrics.pillSize(onRight: false).width > OverlayMetrics.pillSize(onRight: false).height,
                "upright pill on the right, wide pill at the bottom")
    }

}
