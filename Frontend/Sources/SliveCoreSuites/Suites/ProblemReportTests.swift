import Foundation
import SliveReport
import SliveTestKit

/// Problem reports (privacy first)
@MainActor
enum ProblemReportTests {
    static let suite = TestSuite(name: "Problem reports") { t in
        print("[Problem reports]")
        let r = Redactor(userName: "priya", fullName: "Priya Raman", homeDirectory: "/Users/priya",
                         hostNames: ["Priyas-MacBook-Air.local", "Priya’s MacBook Air"],
                         deviceNames: ["Priya’s AirPods Pro", "HP H250"])
        func clean(_ s: String) -> String { r.clean(s) }
        func leaks(_ s: String) -> Bool { s.lowercased().contains("priya") || s.lowercased().contains("raman") }

        let home = clean("saved /Users/priya/Library/Application Support/Slive/history.json")
        t.check(!leaks(home) && home.contains("~/Library"), "home path → ~", home)
        t.equal(clean("other /Users/sam/x.txt"), "other /Users/<user>/x.txt", "another user's path")
        t.check(!leaks(clean("mic Priya’s AirPods Pro connected")), "this Mac's device name removed")
        t.check(clean("HP H250 input").contains("<device>"), "plain device name removed too")
        t.equal(clean("Sam's AirPods"), "<name>'s AirPods", "any possessive device name")
        t.check(!leaks(clean("host Priyas-MacBook-Air.local up")), "host name removed")
        t.check(!leaks(clean("by Priya Raman")), "full name removed")
        t.check(!clean("key sk-proj-abcdEFGH1234567890abcdXYZ").contains("abcdEFGH"), "OpenAI key removed")
        t.check(!clean("Authorization: Bearer abc.def.ghi123456").contains("abc.def"), "bearer token removed")
        t.check(!clean("k=AIzaSyA1234567890abcdefghijklmnopqrstu").contains("AIza"), "Google key removed")
        t.check(!clean("token hf_abcdefghijklmnopqrstuvwxyz12").contains("hf_abc"), "HF token removed")
        t.equal(clean("mail priya.raman@example.com now"), "mail <email> now", "email removed")
        t.equal(clean("GET https://evil.example.com/a?q=1"), "GET <url>", "unknown URL removed")
        t.equal(clean("POST https://api.openai.com/v1/chat?key=abc"), "POST https://api.openai.com/v1/chat?<…>",
              "known host kept, query dropped")
        let ips = clean("from 192.168.1.20 to 127.0.0.1")
        t.check(ips.contains("<ip>") && ips.contains("127.0.0.1") && !ips.contains("192.168"), "LAN IP removed, loopback kept", ips)
        t.check(clean("uid AA-BB-CC-DD-EE-FF:input").contains("<mac>"), "Bluetooth MAC removed")
        t.check(clean("id 123e4567-e89b-12d3-a456-426614174000").contains("<id>"), "UUID removed")
        t.check(clean("/var/folders/xy/abc123/T/slive-backend.log").contains("<tmp>"), "temp folder removed")
        t.check(clean("blob QmFzZTY0QXVkaW9EYXRhSGVyZTEyMzQ1Njc4OTAxMjM0NTY3OA==").contains("<blob>"), "opaque blob removed")
        let safe = "decoded in 0.31s (distil-whisper_distil-large-v3_turbo_600MB, 54 chars) 10:36:12.123"
        t.equal(clean(safe), safe, "ordinary event line untouched")
        t.equal(r.cleanFreeText("ValueError: bad input 'hello there' for “my words”"),
              "ValueError: bad input '…' for “…”", "quoted free text blanked")
        t.equal(r.cleanFreeText("decoded «what I said»"), "decoded «…»", "guillemet text blanked")
        t.check(r.cleanFreeText("it doesn't load, it's broken").contains("doesn't load, it's"), "apostrophes aren't quotes")

        // Server log lines
        let frame = Collectors.serverLine(#"  File "/Users/priya/.slive/Slive/Backend/src/flowy/server.py", line 120, in x"#, redactor: r) ?? ""
        t.check(!leaks(frame) && frame.contains("server.py") && frame.contains("line 120"), "traceback frame kept, path cleaned", frame)
        t.equal(Collectors.serverLine("httpx.HTTPStatusError: Client error 'x' for url 'https://a.b/c?k=1'", redactor: r),
              "httpx.HTTPStatusError: Client error '…' for url '…'", "exception type kept, message blanked")

        // Crash report: allow-list only
        let ips_ = #"{"app_name":"Slive","timestamp":"2026-11-05 16:06:06.00 +0530","app_version":"0.2.4","bundleID":"com.slive.app","incident_id":"11111111-2222-3333-4444-555555555555"}"#
            + "\n" + #"{"procPath":"/Users/priya/Applications/Slive.app/Contents/MacOS/Slive","crashReporterKey":"SECRETKEY123","userID":501,"modelCode":"Mac16,12","parentProc":"launchd","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x10"},"termination":{"indicator":"Segmentation fault: 11"},"asi":{"libswiftCore.dylib":["Fatal error: nil at /Users/priya/Code/Slive/x.swift:3"]},"faultingThread":0,"threads":[{"triggered":true,"frames":[{"imageIndex":1,"symbol":"swift_retain","symbolLocation":4},{"imageIndex":0,"symbol":"closure #1 in TranscriptionModel.load(_:)","symbolLocation":120,"sourceFile":"/Users/priya/Code/TranscriptionModel.swift","sourceLine":977}]}],"usedImages":[{"name":"Slive","path":"/Users/priya/Applications/Slive.app/Contents/MacOS/Slive"},{"path":"/usr/lib/swift/libswiftCore.dylib"}]}"#
        if let crash = CrashReport.parse(ips_, fileName: "Slive-2026-11-05-160606.ips", redactor: r) {
            let all = ([crash.exception] + crash.messages + crash.frames).joined(separator: "\n")
            t.check(crash.exception.hasPrefix("EXC_BAD_ACCESS (SIGSEGV) · KERN_INVALID_ADDRESS"), "crash exception read", crash.exception)
            t.equal(crash.sliveFrame ?? "", "TranscriptionModel.load(_:)", "crash's Slive frame")
            t.check(crash.frames.count == 2 && crash.frames[1].contains("TranscriptionModel.swift:977"), "crash frames with file:line")
            t.check(!leaks(all) && !all.contains("SECRETKEY") && !all.contains("Mac16") && !all.contains("11111111"),
                  "crash report: nothing outside the allow-list", all)
        } else {
            t.check(false, "crash report parses")
        }
        t.equal(CrashReport.meaningfulSymbol("thunk for @escaping @callee_guaranteed @Sendable () -> ()"), nil, "thunk frames skipped")
        t.equal(CrashReport.meaningfulSymbol("main"), nil, "main is not a failure point")
        t.equal(CrashReport.meaningfulSymbol("closure #2 in AppDelegate.beginRecording()"), "AppDelegate.beginRecording()",
              "closure named by its function")
        t.check(CrashReport.isSliveCrashFile("Slive-2026-11-05-160606.ips"), "Slive crash file name")
        t.check(!CrashReport.isSliveCrashFile("SliveReporter-2026-11-05-160606.ips"), "reporter's own crash ignored")
        t.check(!CrashReport.isSliveCrashFile("ExcUserFault_Slive-2026-11-05-160606.ips"), "other report kinds ignored")

        // Hang sample: heaviest main-thread path, no header, no addresses
        let sample = """
        Process:         Slive [41831]
        Path:            /Users/priya/Applications/Slive.app/Contents/MacOS/Slive
        Parent Process:  launchd [1]

        Call graph:
            900 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 900 start  (in dyld) + 6688  [0x18294be80]
            +   900 main  (in Slive) + 844  [0x10043243c]  main.swift:81
            +     840 PasteEngine.probeFocus()  (in Slive) + 52  [0x100500000]  PasteEngine.swift:212
            +     ! 840 AXUIElementCopyAttributeValue  (in HIServices) + 20  [0x190000000]
            +     ! : 840 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x182cdcc20]
            +     60 -[NSApplication run]  (in AppKit) + 396  [0x18738b90c]
            +       60 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x182cdcc20]
            900 Thread_2: com.apple.NSEventThread
            + 900 thread_start  (in libsystem_pthread.dylib) + 8  [0x1]
        """
        if let hang = HangSample.parse(sample, redactor: r) {
            let all = hang.frames.joined(separator: "\n")
            t.check(hang.frames.first?.contains("mach_msg2_trap") == true && hang.frames.count == 5, "hang: heaviest path, top first", all)
            t.equal(hang.sliveFrame ?? "", "PasteEngine.probeFocus()", "hang's Slive frame")
            t.check(!leaks(all) && !all.contains("[0x") && !all.contains("NSApplication run"), "hang: no paths, addresses or lighter branches", all)
        } else {
            t.check(false, "hang sample parses")
        }

        // The GitHub link
        t.equal(ProblemReport.encode("a+b&c=d e"), "a%2Bb%26c%3Dd%20e", "strict URL encoding")
        var report = ProblemReport(kind: .crash, headline: "EXC_BAD_ACCESS in X", summary: "Slive quit unexpectedly.",
                                   failurePoint: Array(repeating: String(repeating: "f", count: 120), count: 24),
                                   build: BuildInfo(version: "0.2.4", edition: "Lite", commit: "a7a0746-dirty", commitDate: nil),
                                   system: SystemInfo(macOS: "27.0", chip: "Apple M4", memoryGB: 16),
                                   appLog: Array(repeating: String(repeating: "l", count: 200), count: 300),
                                   serverLog: Array(repeating: String(repeating: "s", count: 200), count: 60))
        let url = report.issueURL().absoluteString
        t.check(url.count <= ProblemReport.maxURLLength, "issue link fits GitHub's limit", "\(url.count)")
        t.check(url.hasPrefix("https://github.com/SoumilB7/Slive/issues/new?title=Crash"), "issue link targets Slive's repo")
        report.appLog = []
        t.check(report.markdown().contains("commit/a7a0746)"), "commit link drops -dirty")
        let message = ReporterMessage(kind: .failure, failure: Failure(area: "server", title: "t", detail: nil, source: "x:1 f()"))
        if let line = message.encodedLine(), line.last == 0x0A,
           let back = try? JSONDecoder().decode(ReporterMessage.self, from: line.dropLast()) {
            t.check(back.kind == .failure && back.failure == message.failure, "reporter message round-trips")
        } else {
            t.check(false, "reporter message encodes")
        }
    }
}
