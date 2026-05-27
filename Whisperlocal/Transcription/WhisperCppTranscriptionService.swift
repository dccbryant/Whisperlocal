import Foundation
import whisper

/// On-device transcription powered by whisper.cpp.
///
/// The context is large (loaded model + KV cache), so we hold it on an actor and reuse it
/// across calls. The first call pays the model-load cost; subsequent calls are much faster.
actor WhisperCppTranscriptionService: TranscriptionService {
    enum WhisperError: Error, LocalizedError {
        case modelNotFound
        case contextInitFailed
        case decodeFailed(Error)
        case inferenceFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .modelNotFound: return "Whisper model not found on device."
            case .contextInitFailed: return "Failed to load Whisper model."
            case .decodeFailed(let e): return "Audio decode failed: \(e.localizedDescription)"
            case .inferenceFailed(let code): return "Whisper inference failed (code \(code))."
            }
        }
    }

    private var ctx: OpaquePointer?
    private let modelURL: URL

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    private func ensureLoaded() throws {
        if ctx != nil { return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperError.modelNotFound
        }
        var params = whisper_context_default_params()
        params.use_gpu = true
        let loaded: OpaquePointer? = modelURL.path.withCString { cpath in
            whisper_init_from_file_with_params(cpath, params)
        }
        guard let loaded else { throw WhisperError.contextInitFailed }
        ctx = loaded
    }

    func transcribe(audioAt url: URL) async throws -> String {
        try ensureLoaded()
        guard let ctx else { throw WhisperError.contextInitFailed }

        let samples: [Float]
        do {
            samples = try AudioDecoder.decodeToPCM16k(url: url)
        } catch {
            throw WhisperError.decodeFailed(error)
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.suppress_blank = true
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))

        let status: Int32 = "en".withCString { langPtr in
            params.language = langPtr
            return samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }

        guard status == 0 else { throw WhisperError.inferenceFailed(status) }

        var text = ""
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cstr)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
