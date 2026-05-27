import Foundation

/// Single source of truth for "is the Whisper model on disk and where is it".
///
/// Resolution order:
///   1. A copy bundled into the app at `Resources/Models/<filename>` (Phase-2 dev convenience).
///   2. A previously downloaded copy under `Application Support/Models/<filename>`.
///
/// If neither exists, the user is shown the download UI on first launch.
enum ModelStore {
    /// Default model: small.en quantized — ~190 MB, English only, best accuracy/size tradeoff.
    static let filename = "ggml-small.en-q5_1.bin"

    static let remoteURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)"
    )!

    /// Expected size in bytes (approximate; only used for progress UI fallback).
    static let approxBytes: Int64 = 190_000_000

    /// URL where a downloaded model is stored.
    static func downloadedURL() -> URL {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (support ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    /// URL to the bundled copy, if the developer dropped one into `Resources/Models/`.
    static func bundledURL() -> URL? {
        Bundle.main.url(forResource: (filename as NSString).deletingPathExtension, withExtension: "bin")
    }

    /// First-found model location, or nil if not yet available.
    static func resolvedURL() -> URL? {
        if let bundled = bundledURL() { return bundled }
        let downloaded = downloadedURL()
        return FileManager.default.fileExists(atPath: downloaded.path) ? downloaded : nil
    }

    static var isAvailable: Bool { resolvedURL() != nil }
}
