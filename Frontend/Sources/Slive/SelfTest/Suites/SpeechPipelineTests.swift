import Foundation
import SliveTestKit

/// Model catalog + dictation pipeline: catalog invariants (persisted ids and
/// defaults resolve, engine routing), stage order, and byte-equivalence of
/// the pipeline with the pre-pipeline code (frozen copies in `Legacy`).
@MainActor
enum SpeechPipelineTests {
    static let suite = TestSuite(name: "Model catalog + pipeline") { t in
        print("[Model catalog + pipeline]")
        catalog(&t)
        pipeline(&t)
    }

    // MARK: - Catalog

    private static func catalog(_ t: inout Checks) {
        let ids = ModelCatalog.all.map(\.id)
        t.check(Set(ids).count == ids.count, "catalog ids are unique")
        t.equal(ids, ["tiny.en", "base.en", "large-v3-v20240930_626MB", "large-v3", "parakeet-ultra", "parakeet-v2"],
                "persisted id strings and picker order unchanged")
        t.equal(ModelCatalog.all.map(\.label),
                ["Whisper – tiny.en", "Whisper – base.en", "Whisper – large-v3 turbo", "Whisper – large-v3",
                 "Parakeet – Ultra", "Parakeet – v2"], "picker labels unchanged")
        t.equal(ModelCatalog.all.map(\.detail),
                ["Fastest · 75 MB", "Fast · 150 MB", "Recommended · 600 MB", "Most accurate · 1.5 GB",
                 "Fastest · weaker on names · 610 MB", "English · 450 MB"], "picker detail lines unchanged")
        t.check(ModelCatalog.lists.allSatisfy { list in list.allSatisfy { $0.engine == list.first?.engine } },
                "each catalog list is one engine")

        // Defaults are persisted strings: they must stay resolvable.
        t.equal([ModelCatalog.defaultDictation, ModelCatalog.defaultContinuous, ModelCatalog.defaultGroundTruth,
                 ModelCatalog.balanced], ["tiny.en", "parakeet-ultra", "large-v3", "large-v3-v20240930_626MB"],
                "default model ids unchanged")
        let dictation = ModelCatalog.descriptor(ModelCatalog.defaultDictation)
        t.check(dictation?.uses.contains(.dictation) == true && dictation?.bundled == true,
                "default dictation model resolves, is offered for dictation and ships bundled")
        t.check(ModelCatalog.descriptor(ModelCatalog.defaultContinuous)?.uses.contains(.continuous) == true,
                "default continuous model resolves and is offered for continuous")
        t.check(ModelCatalog.descriptor(ModelCatalog.defaultGroundTruth)?.uses.contains(.groundTruth) == true,
                "default ground-truth Whisper model resolves and is offered for ground truth")
        t.check(ModelCatalog.descriptor(ModelCatalog.balanced)?.engine == .whisper,
                "the Balanced suggestion is a catalog Whisper model")
        t.equal(ModelCatalog.all.filter(\.bundled).map(\.id), ["tiny.en"], "exactly one bundled model: tiny.en")

        // Engine routing.
        t.check(["tiny.en", "large-v3-v20240930_626MB", "base.en", "my-finetune-2026", "distil-large-v3", ""]
                .allSatisfy { ModelCatalog.engine(of: $0) == .whisper && SpeechEngine.of($0).kind == .whisper },
                "legacy bare ids and unknown/custom ids route to Whisper")
        t.check(ParakeetModel.allCases.allSatisfy {
                    ModelCatalog.engine(of: $0.rawValue) == .parakeet && SpeechEngine.of($0.rawValue) == .parakeet($0)
                }, "every Parakeet id routes to its Parakeet model")
        t.equal(ModelCatalog.ids(of: .parakeet), ParakeetModel.allCases.map(\.rawValue),
                "the catalog lists every Parakeet model, in enum order")

        // Picker sections (moved from Silence trim: Parakeet separate from Whisper).
        let whisperIDs = ModelCatalog.ids(of: .whisper)
        let parakeetIDs = ModelCatalog.ids(of: .parakeet)
        t.check(parakeetIDs == ParakeetModel.allCases.map(\.rawValue)
                && Set(whisperIDs).isDisjoint(with: parakeetIDs),
                "picker: Parakeet entries separate from the Whisper list")
        t.check(ModelCatalog.sections(for: .dictation).map { $0.map(\.id) } == [whisperIDs, parakeetIDs],
                "dictation picker: Whisper section, then Parakeet")
        t.check(ModelCatalog.sections(for: .continuous).map { $0.map(\.id) } == [whisperIDs, parakeetIDs],
                "continuous picker: Whisper section, then Parakeet")
        t.check(ModelCatalog.sections(for: .groundTruth).map { $0.map(\.id) } == [whisperIDs],
                "ground-truth picker: Whisper only")

        // Lookup the picker + status line use.
        t.check(ModelCatalog.resolve("nope", custom: []) == nil, "unknown id resolves to nothing (\"Custom\")")
        t.check(ModelCatalog.resolve("parakeet-ultra", for: .groundTruth, custom: []) == nil,
                "a model not offered for a use reads as Custom there")
        t.equal(ModelCatalog.resolve("parakeet-ultra", custom: [])?.label, "Parakeet – Ultra",
                "status line names a Parakeet model")
        if let custom = makeCustomModel() {
            let d = ModelCatalog.resolve(custom.id, for: .groundTruth, custom: [custom])
            t.check(d?.label == "My Fine-tune" && d?.detail == "Fine-tuned large-v3 · slive-test-ft"
                    && d?.engine == .whisper,
                    "installed fine-tune resolves with its name and \"Fine-tuned <base> · <id>\"")
        } else {
            t.check(false, "custom model fixture loads")
        }
    }

    /// A minimal installed fine-tune in a temp folder (manifest, the three
    /// model files, a local tokenizer), read through the real registry.
    private static func makeCustomModel() -> CustomWhisperModel? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slive-selftest-custom-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let manifest = """
        {"id": "slive-test-ft", "display_name": "My Fine-tune", "base_model": "large-v3",
         "model_folder": "model", "tokenizer_folder": "tokenizer"}
        """
        do {
            for name in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] {
                try fm.createDirectory(at: root.appendingPathComponent("model/\(name).mlmodelc"),
                                       withIntermediateDirectories: true)
            }
            let tok = root.appendingPathComponent("tokenizer/models/openai/whisper-large-v3")
            try fm.createDirectory(at: tok, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: tok.appendingPathComponent("tokenizer.json"))
            try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))
        } catch { return nil }
        return CustomWhisperModelRegistry.model(in: root)
    }

    // MARK: - Pipeline

    private static func pipeline(_ t: inout Checks) {
        t.equal(DictationPipeline.standard(vocabulary: "").order,
                ["SilenceTrim", "decode", "StreamHygiene", "VocabularyCorrection"],
                "standard order: trim → decode → clean → vocabulary")
        t.equal(DictationPipeline.live(vocabulary: "").order,
                ["SilenceTrim", "decode", "StreamHygiene", "LeadingSpaceStrip", "VocabularyCorrection"],
                "live order adds the leading-space strip to cleanup")
        var probed = DictationPipeline.standard(vocabulary: "z-docs")
        probed.corrections.append(Uppercase())
        t.equal(probed.finish("<|en|> see z docs"), " SEE Z-DOCS",
                "an added stage runs after vocabulary (and cleanup ran first)")

        // Audio: the pipeline's trim == the pre-pipeline trim, same slice.
        var sameSlices = true
        for buffer in audioCorpus() {
            let new = DictationPipeline.standard(vocabulary: "").prepare(buffer)
            let old = Legacy.trimSilence(buffer)
            let forwarded = TranscriptionModel.trimSilence(buffer)
            if new.startIndex != old.startIndex || new.endIndex != old.endIndex
                || forwarded.startIndex != old.startIndex || forwarded.endIndex != old.endIndex {
                sameSlices = false
            }
        }
        t.check(sameSlices, "silence trim via pipeline = pre-pipeline trim on every test buffer")
        let twice = DictationPipeline(audio: [SilenceTrim(), SilenceTrim()], cleanup: [], corrections: [])
        let sample = audioCorpus()[3]
        t.check(Array(twice.prepare(sample)) == Array(SilenceTrim.trim(Array(SilenceTrim.trim(sample)))),
                "audio stages chain in order")
        t.check(DictationPipeline(audio: [], cleanup: [], corrections: []).prepare(sample).count == sample.count,
                "no audio stages → samples untouched")

        // Text: every caller's new path == its old static sequence.
        var standardSame = true, liveSame = true, appSame = true, labelSame = true, benchSame = true
        var parakeetSame = true
        for vocabulary in vocabularies {
            let standard = DictationPipeline.standard(vocabulary: vocabulary)
            let live = DictationPipeline.live(vocabulary: vocabulary)
            for text in textCorpus {
                let oldCorrect = { (s: String) in VocabularyCorrector.correct(s, hotwords: vocabulary) }
                if standard.finish(text) != oldCorrect(Legacy.clean(text)) { standardSame = false }
                // ContinuousDictation: live pass, final pass pieces.
                if live.finish(text) != oldCorrect(Legacy.normalize(text))
                    || live.clean(text) != Legacy.normalize(text)
                    || live.correct(text) != oldCorrect(text) { liveSame = false }
                // App, Whisper in-memory decode (already cleaned by the decode).
                let decoded = Legacy.clean(text)
                if standard.correct(standard.clean(decoded)) != oldCorrect(decoded) { appSame = false }
                // App, Parakeet decode (never had cleanup): same on artifact-free text.
                if !text.contains("<|"), !text.contains("Waiting for speech..."),
                   standard.correct(standard.clean(text)) != oldCorrect(text) { parakeetSame = false }
                // LabelRun: corrections only.
                if standard.correct(text) != oldCorrect(text) { labelSame = false }
            }
        }
        for text in textCorpus where BenchSupport.pipeline.finish(text) != Legacy.clean(text) { benchSame = false }
        t.check(standardSame, "standard pipeline = old clean → vocabulary")
        t.check(liveSame, "continuous: live pipeline = old normalize → vocabulary (stream, seam, final)")
        t.check(appSame, "app (Whisper): cleanup after the decode's own clean changes nothing")
        t.check(parakeetSame, "app (Parakeet): cleanup changes nothing on artifact-free text")
        t.check(labelSame, "ground-truth labels: corrections = old VocabularyCorrector call")
        t.check(benchSame, "benches: no Vocabulary, cleanup only = old cleanStreamText")
        t.check(textCorpus.allSatisfy {
                    TranscriptionModel.cleanStreamText($0) == Legacy.clean($0)
                    && ContinuousDictation.normalize($0) == Legacy.normalize($0)
                }, "forwarding statics (cleanStreamText, normalize) = pre-pipeline code")
        t.check(textCorpus.allSatisfy { DictationPipeline.standard(vocabulary: "").correct($0) == $0 },
                "empty vocabulary corrects nothing")
    }

    private struct Uppercase: TextStage {
        func apply(_ text: String) -> String { text.uppercased() }
    }

    private static let vocabularies = ["", "z-docs, OnFinance\ncos-mp-agent", "claude, argo cd, ios, cos"]

    /// Shapes the decoders really produce, plus their artifacts.
    private static let textCorpus = [
        "", " ", " Hello world.", " I think we should ship it", "  hello there", "a  b",
        "<|startoftranscript|><|en|><|transcribe|><|0.00|> hello world<|endoftext|>",
        "Waiting for speech...", "Waiting for speech... hi", "<|en|>hi", "Hi <|0.00|>there",
        " Check the Z docs and on finance, then CosMP agents.", "Claude and iOS on argo CD",
        " the cause is curls, not cos", "café — naïve 😀 émigré", "Line one\nline two",
        "z docs. ZDocs, z-docs!", " (Z docs)", "on finances matter",
    ]

    /// Silence, padded voice, soft tails, a noisy room, sub-frame, and a
    /// deterministic noise-with-bursts clip.
    private static func audioCorpus() -> [[Float]] {
        let rate = 16_000
        let quiet = [Float](repeating: 0.001, count: rate)
        let voice = [Float](repeating: 0.1, count: rate / 2)
        let room = [Float](repeating: 0.0005, count: rate)
        let softTail = [Float](repeating: 0.005, count: rate * 2 / 5)
        let noisy = [Float](repeating: 0.003, count: rate)
        var seed: UInt32 = 12_345
        let bursty: [Float] = (0..<(rate * 3)).map { i in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.004
            return (rate..<(rate * 2)).contains(i) ? noise + 0.08 * Float(sin(Double(i) * 0.05)) : noise
        }
        return [
            [], [Float](repeating: 0, count: 100), quiet, quiet + voice + quiet,
            room + voice + softTail + room, room + softTail + room,
            noisy + [Float](repeating: 0.05, count: rate) + [Float](repeating: 0.007, count: rate * 2 / 5) + noisy,
            voice, bursty,
        ]
    }

    /// Frozen copies of the code before the pipeline existed — the reference
    /// the pipeline must match byte for byte.
    private enum Legacy {
        static func clean(_ text: String) -> String {
            var t = text.replacingOccurrences(of: "Waiting for speech...", with: "")
            if t.contains("<|") {
                t = t.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            }
            return t
        }

        static func normalize(_ text: String) -> String {
            var t = text.replacingOccurrences(of: "Waiting for speech...", with: "")
            if t.contains("<|") {
                t = t.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            }
            while t.first == " " { t.removeFirst() }
            return t
        }

        static func trimSilence(_ samples: [Float]) -> ArraySlice<Float> {
            let frame = 160
            let frames = samples.count / frame
            guard frames > 0 else { return samples[0..<0] }
            var rms = [Float](repeating: 0, count: frames)
            var loudest: Float = 0
            for f in 0..<frames {
                var sum: Float = 0
                for j in (f * frame)..<(f * frame + frame) { sum += samples[j] * samples[j] }
                rms[f] = (sum / Float(frame)).squareRoot()
                loudest = max(loudest, rms[f])
            }
            guard loudest > 0.01 else { return samples[0..<0] }
            let threshold = edgeThreshold(frameRMS: rms)
            let tailThreshold = max(1.5 * noiseFloor(frameRMS: rms), 0.5 * threshold)
            guard let first = rms.firstIndex(where: { $0 > threshold }),
                  let last = rms.lastIndex(where: { $0 > min(threshold, tailThreshold) }) else { return samples[0..<0] }
            let start = max(0, first * frame - 2_400)
            let end = min(samples.count, (last + 1) * frame + 4_800)
            return samples[start..<end]
        }

        static func edgeThreshold(frameRMS: [Float]) -> Float {
            guard !frameRMS.isEmpty else { return 0.01 }
            return min(0.01, max(0.003, 4 * noiseFloor(frameRMS: frameRMS)))
        }

        static func noiseFloor(frameRMS: [Float]) -> Float {
            guard !frameRMS.isEmpty else { return 0 }
            let sorted = frameRMS.sorted()
            return sorted[min(sorted.count - 1, sorted.count / 10)]
        }
    }
}
