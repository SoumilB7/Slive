import AppKit
import ApplicationServices

/// Turns on accessibility in Chromium/Electron apps, which build their AX
/// tree only for clients that ask. Asleep, they answer "nothing focused"
/// whether a text field has focus or not (Nov 23, Brave: the same answer for
/// the YouTube search box and the bare page), so no rule can tell "type" from
/// "copy box". `AXManualAccessibility` is the request made for exactly this
/// (Electron honours it); browsers refuse it and need `AXEnhancedUserInterface`
/// (the screen-reader flag), tried second. Once awake, the focused field — or
/// the page, a link — is reported, and `TypingPolicy` decides on real facts.
///
/// Asked once per process: when the app comes to the front and again on a
/// hold (cheap after the first), so the tree is built while the user speaks.
@MainActor
enum AXWake {
    /// When each lazy app was last asked. Chromium switches its tree back
    /// off when no assistive client has asked for a while (Nov 26: Brave,
    /// woken on the 23rd, answered "nothing focused" again), and an ask can
    /// time out on a busy app (Slack, -25204) — so asks repeat, throttled.
    private static var lastAsked: [pid_t: Date] = [:]
    /// Native apps and code editors: never asked.
    private static var never: Set<pid_t> = []
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { wakeIfLazy(app) }
        }
        wakeIfLazy(NSWorkspace.shared.frontmostApplication)
    }

    /// Ask `app` (if it's a lazy-AX app) to build its tree, at most every
    /// `minInterval` seconds. A hold asks with a short interval, so the tree
    /// is being built while the user speaks. The AX write runs off the main
    /// thread: it's bounded, but a hung app would still cost the timeout.
    static func wakeIfLazy(_ app: NSRunningApplication?, minInterval: TimeInterval = 10) {
        guard let app else { return }
        let pid = app.processIdentifier
        guard !never.contains(pid) else { return }
        // VS Code-based editors watch for assistive tech and can switch to
        // screen-reader mode when their tree is turned on: left asleep, they
        // keep fail-open typing (see `TypingSink`).
        guard FocusProbe.appHasLazyAX(app), !FocusProbe.engine(of: app).codeEditor else {
            never.insert(pid)
            return
        }
        let now = Date()
        if let last = lastAsked[pid], now.timeIntervalSince(last) < minInterval { return }
        lastAsked[pid] = now
        let name = app.bundleIdentifier ?? "?"
        DispatchQueue.global(qos: .utility).async {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, FocusProbe.axTimeout)
            let manual = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            guard manual != .success else { return }
            // Electron honours the manual flag; Chrome, Brave and Arc refuse it
            // (-25205, Nov 23) and turn their tree on for the screen-reader flag
            // — which answers -25208 yet works. Its known cost: some window
            // managers animate their windows more slowly while it's set.
            let enhanced = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            Log.paste("wake \(name): manual \(manual.rawValue), enhanced \(enhanced.rawValue)")
        }
    }
}
