import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    enum RecorderError: Error {
        case permissionDenied
        case sessionConfigFailed(Error)
        case recorderInitFailed(Error)
    }

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Live peak level in dBFS while recording. -160 means silence (mic likely disconnected
    /// or denied); typical speech sits between -30 and -5 dB.
    @Published private(set) var peakLevel: Float = -160

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var timer: Timer?

    func start() async throws -> URL {
        try await requestPermission()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            throw RecorderError.sessionConfigFailed(error)
        }

        // 16 kHz mono 16-bit linear PCM in a WAV container — the exact format Whisper expects
        // internally, so WhisperKit can ingest it without re-decoding or resampling.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        let url = Self.makeRecordingURL()
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else {
                throw RecorderError.recorderInitFailed(NSError(domain: "AudioRecorder", code: -1))
            }
            recorder = r
        } catch {
            throw RecorderError.recorderInitFailed(error)
        }

        startedAt = Date()
        isRecording = true
        startTimer()
        return url
    }

    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        startedAt = nil
        isRecording = false
        elapsed = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(start)
                if let r = self.recorder {
                    r.updateMeters()
                    self.peakLevel = r.peakPower(forChannel: 0)
                }
            }
        }
    }

    private func requestPermission() async throws {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            return
        case .denied:
            throw RecorderError.permissionDenied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw RecorderError.permissionDenied }
        @unknown default:
            throw RecorderError.permissionDenied
        }
    }

    private static func makeRecordingURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("\(name).wav")
    }
}
