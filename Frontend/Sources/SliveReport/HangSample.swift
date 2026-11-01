import Foundation

/// Where Slive's main thread is stuck, from `/usr/bin/sample` output: the
/// heaviest path of the main thread's call graph, top of stack first. Only
/// the call graph is read — never the header (its `Path:` and `Parent
/// Process:` lines) or the binary-image list (full paths).
public struct HangSample: Sendable, Equatable {
    /// Top of stack first: "Slive  PasteEngine.probeFocus() (PasteEngine.swift:212)"
    public var frames: [String]
    /// The deepest frame in Slive's own code, for the issue title.
    public var sliveFrame: String?

    public static func parse(_ text: String, redactor: Redactor) -> HangSample? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("com.apple.main-thread") }) else { return nil }

        // Each call-graph line: tree markers (+ ! : |) and spaces, then
        // "<count> <symbol>  (in <image>) + <offset>  [0x…]  <file>:<line>".
        // A line's depth is where its count starts; children come right after
        // their parent, heaviest first — so following "next line is deeper"
        // walks the heaviest path.
        var path: [(depth: Int, text: String)] = []
        var i = start + 1
        while i < lines.count, let (depth, rest) = split(lines[i]) {
            if let last = path.last, depth <= last.depth { break }
            path.append((depth, rest))
            i += 1
        }
        guard !path.isEmpty else { return nil }

        var frames = [String]()
        var sliveFrame: String?
        for (_, rest) in path.reversed() {
            guard let frame = format(rest) else { continue }
            frames.append(redactor.clean(frame.text))
            if sliveFrame == nil, frame.image == "Slive", let symbol = CrashReport.meaningfulSymbol(frame.symbol) {
                sliveFrame = redactor.clean(symbol)
            }
        }
        return HangSample(frames: Array(frames.prefix(24)), sliveFrame: sliveFrame)
    }

    /// (depth, text after the count) — nil when the line isn't a call-graph line.
    private static func split(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("    ") else { return nil }
        var depth = 0
        var index = line.startIndex
        while index < line.endIndex, " +!:|".contains(line[index]) {
            depth += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index].isNumber else { return nil }
        while index < line.endIndex, line[index].isNumber { index = line.index(after: index) }
        return (depth, line[index...].trimmingCharacters(in: .whitespaces))
    }

    private static func format(_ rest: String) -> (text: String, image: String, symbol: String)? {
        guard let inRange = rest.range(of: "  (in ") else { return nil }
        let symbol = String(rest[..<inRange.lowerBound])
        let after = rest[inRange.upperBound...]
        guard let close = after.firstIndex(of: ")") else { return nil }
        let image = String(after[..<close])
        var text = image.padding(toLength: max(image.count, 18), withPad: " ", startingAt: 0) + "  " + symbol
        // Trailing "file.swift:81" when symbolicated.
        if let last = rest.split(separator: " ").last, last.contains(":"), !last.hasPrefix("[") {
            text += "  (" + (String(last) as NSString).lastPathComponent + ")"
        }
        return (text, image, String(symbol.prefix(90)))
    }
}
