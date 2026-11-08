import Foundation
import SliveCore
import SliveTestKit

/// Both dictation pipelines under every kind of Vocabulary a user can type
/// (empty, typical, 60 entries, unicode, regex metacharacters, overlapping
/// terms, symbols only) over a corpus of decoded texts, and silence trim on
/// the clips a mic can hand it (empty, a few samples, under 0.3 s, silence,
/// clipped, NaN/Inf). Every combination runs: no crash, and output a user
/// would accept.
@MainActor
enum PipelineConfigTests {
    static let suite = TestSuite(name: "Pipeline configs") { t in
        print("[Pipeline configs]")
        vocabularies(&t)
        clips(&t)
    }

    // MARK: - Vocabulary × text × pipeline

    static let vocabularies: [(name: String, hotwords: String)] = [
        ("empty", ""),
        ("blank", " ,\n , ,\n"),
        ("typical", "claude, complianceos, cos, ios, onfinance, cos-ai-agent, argo cd, cos-mp-agent, curl, z-docs"),
        ("60 entries", (1...60).map { "proj-\(["alpha", "beta", "gamma"][$0 % 3])-\($0)" }.joined(separator: ", ")
            + ", OnFinance, z-docs"),
        ("unicode", "Zoë, café-bar, naïve, 東京, Ærø, résumé-v2, 🚀launch"),
        ("regex metacharacters", #"c++, .net, a|b, (x), [y], $HOME, ^start, \d+, *.swift, foo?bar, {brace}, back\slash"#),
        ("overlapping", "argo, argo cd, argocd-server, cos, cos-mp, cos-mp-agent, z-docs, z-docs-v2, zdocs"),
        ("symbols only", "+++, ..., ---, ***, @@@"),
        ("newlines and duplicates", "z-docs\nZ-Docs\n\nz docs,ZDOCS\r\nonfinance"),
    ]

    static let longText = (0..<300).map { ["we", "ship", "the", "z", "docs", "build", "on", "finance", "today."][$0 % 9] }
        .joined(separator: " ")

    static let texts: [String] = [
        "",
        "   ",
        " hello world",
        "Check the Z docs folder, then ask the CosMP agent.",
        "<|startoftranscript|><|en|> deploy with argocd now<|endoftext|>",
        "Waiting for speech...",
        "Zoe met the naive cafe bar crew in Tokyo 東京 🚀 today",
        "Use c plus plus and dot net, a or b, x and y, home, start.",
        "Ordinary words: cause, eyes, curls, costs and a lot of compliance.",
        "argo cd and argo and cos mp agent and z docs v2",
        "(Z docs), \"on finance\"? — z — docs",
        "line one\nline two\ttabbed  double  spaced",
        longText,
    ]

    private static func vocabularies(_ t: inout Checks) {
        let pipelines: [(String, (String) -> DictationPipeline)] = [
            ("standard", { DictationPipeline.standard(vocabulary: $0) }),
            ("live", { DictationPipeline.live(vocabulary: $0) }),
        ]
        var failures: [String: [String]] = [:]
        var order: [String] = []
        var runs = 0
        let t0 = Date()
        for (pipelineName, make) in pipelines {
            for vocab in vocabularies {
                let pipeline = make(vocab.hotwords)
                let terms = VocabularyCorrector.terms(from: vocab.hotwords)
                for text in texts {
                    runs += 1
                    let out = pipeline.finish(text)
                    let label = "\(pipelineName)/\(vocab.name)/\(text.prefix(24))"
                    func expect(_ name: String, _ ok: Bool) {
                        if !order.contains(name) { order.append(name) }
                        if !ok { failures[name, default: []].append("\(label) → \(out.prefix(60))") }
                    }
                    expect("no Whisper control token or placeholder survives",
                           !out.contains("<|") && !out.contains("Waiting for speech..."))
                    expect("the live pipeline never starts a field with a space",
                           pipelineName != "live" || !out.hasPrefix(" "))
                    expect("an empty or symbols-only vocabulary changes nothing but artifacts",
                           !terms.isEmpty || out == pipeline.clean(text))
                    expect("correcting twice changes nothing more", pipeline.correct(out) == out)
                    expect("a term already spelled the user's way stays exactly as typed",
                           terms.allSatisfy { !pipeline.clean(text).contains($0.form) || out.contains($0.form) })
                    expect("corrections never eat the text (at most four heard words become one term)",
                           out.split(whereSeparator: \.isWhitespace).count
                               >= pipeline.clean(text).split(whereSeparator: \.isWhitespace).count / 4)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(t0)
        t.check(runs == pipelines.count * vocabularies.count * texts.count,
                "\(runs) runs: 2 pipelines × \(vocabularies.count) vocabularies × \(texts.count) texts")
        for name in order {
            let failed = failures[name] ?? []
            t.check(failed.isEmpty, name, "\(failed.count) runs, e.g. " + failed.prefix(3).joined(separator: " | "))
        }
        t.check(elapsed < 2, "every vocabulary on every text (a 300-word one too) in under 2 s",
                String(format: "%.2fs", elapsed))

        let typical = DictationPipeline.standard(vocabulary: vocabularies[2].hotwords)
        t.equal(typical.finish("Check the Z docs folder, then ask the CosMP agent."),
                "Check the z-docs folder, then ask the cos-mp-agent.", "typical vocabulary still corrects")
        let big = DictationPipeline.standard(vocabulary: vocabularies[3].hotwords)
        t.equal(big.finish("open proj alpha 3 and on finance"), "open proj-alpha-3 and OnFinance",
                "60 entries: terms past the first ten still match")
        let unicode = DictationPipeline.standard(vocabulary: vocabularies[4].hotwords)
        t.equal(unicode.finish("ask zoë at the café bar"), "ask Zoë at the café-bar",
                "unicode terms match their own letters")
        let regex = DictationPipeline.standard(vocabulary: vocabularies[5].hotwords)
        let plain = "Nothing here matches, honestly."
        t.equal(regex.finish(plain), plain, "regex metacharacters in terms are plain text, not patterns")
        // Was "C++++", "..NET", "$$HOME": the symbols already there were kept
        // and the whole form typed after them.
        let symbols = DictationPipeline.standard(vocabulary: "C++, .NET, $HOME, (x), Node.js")
        t.equal(symbols.finish("I write C++ and .NET in $HOME (x) with Node.js."),
                "I write C++ and .NET in $HOME (x) with Node.js.", "a term's own symbols are never typed twice")
        t.equal(symbols.finish("I write c and net in home"), "I write C++ and .NET in $HOME",
                "and a term heard without them still gets them")
    }

    // MARK: - Silence trim on every clip

    static let second = 16_000

    static func tone(_ count: Int, amplitude: Float = 0.3) -> [Float] {
        (0..<count).map { Float(sin(Double($0) * 0.17)) * amplitude }
    }

    static var clipCases: [(name: String, samples: [Float], speech: Bool?)] {
        var nanSpeech = tone(second)
        for i in stride(from: 0, to: nanSpeech.count, by: 997) { nanSpeech[i] = .nan }
        var infSpeech = tone(second)
        infSpeech[8_000] = .infinity
        infSpeech[8_001] = -.infinity
        let padded = [Float](repeating: 0, count: second) + tone(second / 2) + [Float](repeating: 0, count: second)
        return [
            ("0 s", [], false),
            ("1 sample", [0.5], false),
            ("159 samples (under one frame)", tone(159), false),
            ("one 10 ms frame", tone(160), true),
            ("0.25 s of speech", tone(second / 4), true),
            ("0.3 s of speech", tone(second * 3 / 10), true),
            ("1 s of digital silence", [Float](repeating: 0, count: second), false),
            ("1 s of room noise", tone(second, amplitude: 0.002), false),
            ("clipped square wave", (0..<second).map { $0 % 40 < 20 ? 1 : -1 }, true),
            ("overdriven past ±1", tone(second, amplitude: 5), true),
            ("all NaN", [Float](repeating: .nan, count: second), nil),
            ("speech with NaN samples", nanSpeech, nil),
            ("speech with ±Inf samples", infSpeech, nil),
            ("subnormal values", [Float](repeating: .leastNonzeroMagnitude, count: second), false),
            ("speech between seconds of silence", padded, true),
            ("30 s of speech", tone(30 * second), true),
        ]
    }

    private static func clips(_ t: inout Checks) {
        var bad: [String] = []
        for clip in clipCases {
            let trimmed = SilenceTrim.trim(clip.samples)
            let viaPipeline = DictationPipeline.standard(vocabulary: "").prepare(clip.samples)
            var problems: [String] = []
            if trimmed.startIndex < 0 || trimmed.endIndex > clip.samples.count { problems.append("out of bounds") }
            if trimmed.startIndex != viaPipeline.startIndex || trimmed.endIndex != viaPipeline.endIndex {
                problems.append("pipeline differs")
            }
            if trimmed.count > clip.samples.count { problems.append("grew") }
            if let speech = clip.speech, speech == trimmed.isEmpty {
                problems.append(speech ? "speech trimmed away" : "silence kept (\(trimmed.count))")
            }
            if !problems.isEmpty { bad.append("\(clip.name): \(problems.joined(separator: ", "))") }
        }
        t.check(bad.isEmpty, "silence trim on \(clipCases.count) clips (0 s, a frame, <0.3 s, silence, clipped, "
                    + "NaN/Inf, 30 s): in bounds, never grows, speech kept and silence dropped",
                bad.joined(separator: " | "))
        let padded = clipCases.first { $0.name == "speech between seconds of silence" }!.samples
        let kept = SilenceTrim.trim(padded)
        t.check(kept.startIndex >= second - SilenceTrim.leadPad - 160 && kept.startIndex < second
                    && kept.endIndex <= second * 3 / 2 + SilenceTrim.tailPad + 160 && kept.endIndex > second * 3 / 2,
                "dead air on both sides is cut to the pads", "\(kept.startIndex)..<\(kept.endIndex)")
    }
}
