import Foundation

/// Encodes a WAV file to MP3 using the `lame` command-line encoder.
///
/// macOS/AVFoundation can decode MP3 but cannot *encode* it, so we shell out
/// to `lame` (or `ffmpeg` as a fallback) — both live in Homebrew. Output is
/// downsampled to 16 kHz mono, which is exactly what the Gemma 4 E2B audio
/// tower wants and keeps files tiny.
enum Mp3Encoder {

    enum EncodeError: Error, CustomStringConvertible {
        case noEncoderFound
        case encodeFailed(String)
        var description: String {
            switch self {
            case .noEncoderFound:
                return "Neither `lame` nor `ffmpeg` was found. Install with: brew install lame"
            case .encodeFailed(let msg):
                return "MP3 encode failed: \(msg)"
            }
        }
    }

    /// Encode `wavURL` → an .mp3 at `destination`. Returns the destination URL.
    static func encode(wavURL: URL, to destination: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let lame = which("lame") {
            try run(lame, [
                "--silent",
                "-m", "m",            // mono
                "--resample", "16",   // 16 kHz — matches Gemma 4 audio tower
                "-b", "64",           // 64 kbps CBR: ample for speech
                "-q", "2",            // high-quality encoding
                wavURL.path,
                destination.path
            ])
            return destination
        }

        if let ffmpeg = which("ffmpeg") {
            try run(ffmpeg, [
                "-y", "-loglevel", "error",
                "-i", wavURL.path,
                "-ac", "1",
                "-ar", "16000",
                "-b:a", "64k",
                destination.path
            ])
            return destination
        }

        throw EncodeError.noEncoderFound
    }

    // MARK: - Helpers

    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private static func which(_ tool: String) -> String? {
        for dir in searchPaths {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func run(_ launchPath: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw EncodeError.encodeFailed(msg)
        }
    }
}
