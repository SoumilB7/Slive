import Foundation
import SliveTestKit

/// Model residency decisions: the launch stand-in, dictation before
/// continuous, the serving model kept until its replacement is ready.
@MainActor
enum ModelResidencyTests {
    typealias R = ModelResidency

    nonisolated static let turbo = WhisperCatalog.turbo
    nonisolated static let tiny = WhisperCatalog.tiny
    nonisolated static let ultra = ParakeetModel.ultra.rawValue
    nonisolated static let v2 = ParakeetModel.v2.rawValue

    /// Ready implies downloaded; unlisted statuses read `.ready` when
    /// resident, else `.notDownloaded` (TranscriptionModel's defaults).
    static func states(ready: Set<String> = [], downloaded: Set<String> = [],
                       status: [String: TranscriptionModel.Status] = [:]) -> R.States {
        R.States(isReady: { ready.contains($0) },
                 status: { status[$0] ?? (ready.contains($0) ? .ready : .notDownloaded) },
                 isDownloaded: { ready.contains($0) || downloaded.contains($0) })
    }

    static func picks(_ dictation: String = turbo, continuous: String = ultra, on: Bool = false,
                      serving: String? = nil, servingContinuous: String? = nil) -> R.Picks {
        R.Picks(dictation: dictation, continuous: continuous, continuousOn: on,
                servingDictation: serving, servingContinuous: servingContinuous)
    }

    static let suite = TestSuite(name: "Model residency") { t in
        print("[Model residency]")
        let dictateTurbo = R.Plan.dictationFirst(dictation: turbo, continuous: nil, ensureContinuousDownloaded: false)

        // Oct 31: Whisper's compiled copy was purged; its recompile took 70s
        // with nothing to dictate on. A downloaded Parakeet loads first.
        t.equal(R.plan(picks(), states(downloaded: [turbo, ultra])), .standIn(ultra),
                "a cold Whisper pick loads a downloaded Parakeet stand-in first")
        t.equal(R.plan(picks(continuous: v2), states(downloaded: [turbo, ultra, v2])), .standIn(v2),
                "the stand-in is the continuous model when it's a Parakeet")
        t.equal(R.plan(picks(continuous: tiny), states(downloaded: [turbo, v2])), .standIn(v2),
                "else the first downloaded Parakeet in catalog order")
        t.equal(R.plan(picks(), states(downloaded: [turbo, ultra], status: [turbo: .preparing("Loading")])),
                dictateTurbo, "no stand-in once Whisper is already compiling")
        t.equal(R.plan(picks(), states(downloaded: [turbo], status: [turbo: .downloading(0.4)])),
                dictateTurbo, "no stand-in behind a running download")
        t.equal(R.plan(picks(), states(downloaded: [turbo, ultra], status: [ultra: .failed("x")])),
                dictateTurbo, "a failed stand-in is skipped")
        t.equal(R.plan(picks(), states(ready: [ultra], downloaded: [turbo])), dictateTurbo,
                "a ready stand-in hands over to Whisper")
        t.equal(R.plan(picks(serving: tiny), states(ready: [tiny], downloaded: [turbo, ultra])), dictateTurbo,
                "no stand-in while the previous pick still serves")
        t.equal(R.plan(picks(), states(ready: [turbo, ultra])), dictateTurbo, "no stand-in for a ready pick")
        t.equal(R.plan(picks(), states(downloaded: [turbo])), dictateTurbo, "no stand-in without a Parakeet")
        t.equal(R.plan(picks(v2), states(downloaded: [v2, ultra])),
                .dictationFirst(dictation: v2, continuous: nil, ensureContinuousDownloaded: false),
                "a Parakeet pick needs no stand-in")
        t.equal(R.launchStandIn(for: turbo, continuous: ultra, states()), nil, "nothing downloaded → no stand-in")

        // Sep 29: the continuous model's compile ran first and dictation was
        // ready 2m25s after launch. Dictation first; continuous after it.
        t.equal(R.plan(picks(on: true), states(ready: [ultra], downloaded: [turbo])),
                .dictationFirst(dictation: turbo, continuous: ultra, ensureContinuousDownloaded: true),
                "continuous on: dictation, then continuous, then its download check")
        t.equal(R.plan(picks(continuous: turbo, on: true), states(ready: [turbo])),
                .dictationFirst(dictation: turbo, continuous: nil, ensureContinuousDownloaded: true),
                "one model for both is selected once")
        t.check(R.continuousWaits(forDictation: .preparing("Loading"))
                && R.continuousWaits(forDictation: .downloading(0.2)),
                "continuous waits while dictation loads or downloads")
        t.check(!R.continuousWaits(forDictation: .ready) && !R.continuousWaits(forDictation: .notDownloaded)
                && !R.continuousWaits(forDictation: .failed("x")),
                "continuous loads once dictation is ready, missing or failed")

        // The serving model stays until its replacement is ready.
        t.equal(R.keep(picks(), states()), [turbo], "continuous off: only dictation stays")
        t.equal(R.keep(picks(on: true), states()), [turbo, ultra], "continuous on: both stay")
        t.equal(R.keep(picks(serving: tiny), states(ready: [tiny])), [turbo, tiny],
                "the previous pick stays while the new one compiles")
        t.equal(R.keep(picks(serving: tiny), states(ready: [tiny, turbo])), [turbo],
                "and goes once the new one is ready")
        t.equal(R.keep(picks(continuous: v2, on: true, servingContinuous: ultra), states(ready: [ultra])),
                [turbo, v2, ultra], "the previous continuous model stays while its replacement loads")
        t.equal(R.keep(picks(continuous: v2, servingContinuous: ultra), states(ready: [ultra])), [turbo],
                "but not with continuous off")

        // onModelReady: who serves now.
        t.equal(R.promotion(ready: turbo, picks(), states(ready: [turbo])),
                R.Promotion(dictation: turbo), "the pick serves once ready")
        t.equal(R.promotion(ready: ultra, picks(), states(ready: [ultra], downloaded: [turbo])),
                R.Promotion(dictation: ultra, continuous: ultra, isStandIn: true),
                "the stand-in serves while the pick compiles")
        t.equal(R.promotion(ready: ultra, picks(continuous: tiny), states(ready: [ultra, turbo])),
                R.Promotion(), "a stand-in ready after the pick changes nothing")
        t.equal(R.promotion(ready: v2, picks(continuous: v2, on: true), states(ready: [v2])).continuous, v2,
                "the continuous pick serves once ready")

        // The continuous model's auto-download.
        t.equal(R.fetchesContinuous(status: .notDownloaded, retryFailed: false), .start, "missing → fetched")
        t.equal(R.fetchesContinuous(status: .downloading(0.3), retryFailed: true), .running, "a running download is joined")
        t.equal(R.fetchesContinuous(status: .failed("x"), retryFailed: false), .no,
                "a failed download isn't restarted by settings refreshes")
        t.equal(R.fetchesContinuous(status: .failed("x"), retryFailed: true), .start, "a live-typing press retries it")
    }
}
