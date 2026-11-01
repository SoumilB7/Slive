import AppKit
import SliveReport
import SwiftUI

// Slive's problem reporter — a separate little process Slive starts at
// launch, so a frozen or crashed Slive can still be reported.
//
//   SliveReporter --pid <Slive's pid> --app <Slive.app path> --launched <unix time>
//   SliveReporter --demo hang|crash|failure|manual    (shows a panel, for design checks)

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
// Slive closing the pipe mid-write must not kill us.
signal(SIGPIPE, SIG_IGN)

var controller: ReporterController?

if let demo = value("--demo") {
    MainActor.assumeIsolated { Demo.show(demo) }
} else if let pidText = value("--pid"), let pid = Int32(pidText), let appPath = value("--app") {
    let launched = value("--launched").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
    MainActor.assumeIsolated {
        controller = ReporterController(pid: pid, appURL: URL(fileURLWithPath: appPath), launchedAt: launched)
        controller?.start()
    }
} else {
    FileHandle.standardError.write(Data("usage: SliveReporter --pid N --app PATH [--launched T]\n".utf8))
    exit(2)
}

app.run()

/// Sample panels with a realistic report, for checking the design.
@MainActor
enum Demo {
    static var panel: ReportPanel?

    static func show(_ kind: String) {
        let redactor = Redactor.forThisMac()
        let build = BuildInfo(bundle: .main)
        var report = ProblemReport(kind: .hang, headline: "main thread stuck in PasteEngine.probeFocus()",
                                   summary: "Slive's main thread stopped responding for 14 s and then recovered.",
                                   failurePoint: ["Slive               PasteEngine.probeFocus()  (PasteEngine.swift:212)",
                                                  "HIServices          AXUIElementCopyAttributeValue",
                                                  "libsystem_kernel    mach_msg2_trap"],
                                   build: build, system: .current(),
                                   context: ["dictation model": "openai_whisper-large-v3-v20240930_turbo",
                                             "speed": "Relaxed", "live typing": "off"],
                                   appUptime: 1312,
                                   appLog: ["   -42.1s  captured 3.1s audio", "   -41.9s  decoded in 0.31s (large-v3 turbo, 54 chars)",
                                            "    -0.4s  typing 54 chars"])
        report.appLog = report.appLog.map(redactor.clean)
        let model: PanelModel
        switch kind {
        case "crash":
            model = PanelModel(kind: .crash, title: "Slive quit unexpectedly",
                               subtitle: "EXC_BAD_ACCESS (SIGSEGV) in TranscriptionModel.load(_:)")
            model.secondaryTitle = "Reopen Slive"
            model.dismissTitle = "Close"
            report.kind = .crash
        case "failure":
            model = PanelModel(kind: .failure, title: "The speech model failed to load",
                               subtitle: "NSCocoaErrorDomain 4: The file “AudioEncoder.mlmodelc” couldn’t be opened.")
            report.kind = .failure
        case "manual":
            model = PanelModel(kind: .manual, title: "Report a problem",
                               subtitle: "Opens a GitHub issue with Slive's recent log. You describe what went wrong.")
            model.primaryTitle = "Open GitHub"
            model.dismissTitle = "Cancel"
            report.kind = .manual
        default:
            model = PanelModel(kind: .hang, title: "Slive isn't responding", subtitle: "No response for 14 s.")
            model.secondaryTitle = "Restart Slive"
            model.dismissTitle = "Wait"
        }
        model.report = report
        model.showDetails = args.contains("--details")
        model.onDismiss = { NSApp.terminate(nil) }
        model.onReport = { r in print(r.issueURL().absoluteString); NSApp.terminate(nil) }
        if let path = value("--snapshot") {   // render to PNG without showing anything
            snapshot(model, to: path)
            exit(0)
        }
        let p = ReportPanel(model: model)
        panel = p
        p.present()
    }

    static func snapshot(_ model: PanelModel, to path: String) {
        let host = NSHostingView(rootView: ReportCard(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("no bitmap for \(host.bounds)\n".utf8)); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
    }
}
