import Foundation

/// Reads assistant system prompts from the `Backend/prompts` folder. Each
/// `.md`/`.txt` file is a named prompt: the file name (sans extension) is the
/// name shown in Settings, the file contents are the system prompt.
enum PromptLibrary {
    /// Sentinel meaning "don't use a file — use the inline custom prompt".
    static let customName = ""

    /// Absolute path to the prompts folder, or nil if unavailable.
    /// Overridable via FLOWY_PROMPTS_DIR; otherwise the path baked at build time.
    static var directory: URL? {
        if let env = ProcessInfo.processInfo.environment["FLOWY_PROMPTS_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "FlowyPromptsDir") as? String,
           !baked.isEmpty, !baked.contains("__PROMPTS_DIR__") {
            return URL(fileURLWithPath: baked, isDirectory: true)
        }
        return nil
    }

    /// Names of available prompt files (sans extension), sorted, excluding the
    /// README. Empty if the folder is missing.
    static func available() -> [String] {
        guard let dir = directory,
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.lowercased() != "readme" }
            .sorted()
    }

    /// Contents of a named prompt file, trimmed; nil if it can't be read.
    static func contents(named name: String) -> String? {
        guard !name.isEmpty, let dir = directory else { return nil }
        for ext in ["md", "txt"] {
            let url = dir.appendingPathComponent("\(name).\(ext)")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Resolve the effective system prompt for a config: the selected file's
    /// contents if present and readable, otherwise the inline custom prompt.
    static func resolvedSystemPrompt(for config: AssistantConfig) -> String {
        if let fileText = contents(named: config.promptName) { return fileText }
        return config.systemPrompt
    }
}
