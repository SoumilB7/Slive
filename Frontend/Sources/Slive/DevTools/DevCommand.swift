// Dev CLIs: `Slive --bench-*`, `--engine-check`, `--custom-model-check` run one
// task against the real code paths and exit. ModelPreparer is the exception:
// build.sh runs `--prepare-models` from the installed binary, because macOS
// keys the Neural Engine compile cache to that binary.
import Foundation

/// One command-line entry: the flag that selects it and what it runs.
/// To add a CLI, add a row to `DevCommands.all`.
struct DevCommand {
    let flag: String
    let run: @MainActor ([String]) async -> Int32
}

enum DevCommands {
    static let all: [DevCommand] = [
        // would a shorter post-release capture lose words?
        DevCommand(flag: "--bench-tail") { await TailBench.run($0) },
        // compile + warm the models for THIS binary, then exit (run by build.sh)
        DevCommand(flag: "--prepare-models") { _ in await ModelPreparer.run() },
        // how slow are the first dictations after a (re)install?
        DevCommand(flag: "--bench-coldstart") { await ColdStartBench.run($0) },
        // does a trained model the backend installed load and transcribe?
        DevCommand(flag: "--custom-model-check") { await CustomModelCheck.run($0) },
        // Whisper's side of a model comparison
        DevCommand(flag: "--bench-dump") { await DumpBench.run($0) },
        // prove the Parakeet engine loads and transcribes through Slive's code
        DevCommand(flag: "--engine-check") { await EngineCheck.run($0) },
        // which chip should run each Whisper stage on this Mac
        DevCommand(flag: "--bench-compute") { await ComputeBench.run($0) },
    ]

    static func match(_ args: [String]) -> DevCommand? {
        all.first { args.contains($0.flag) }
    }
}
