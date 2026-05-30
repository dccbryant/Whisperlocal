import AVFoundation
import Foundation
import UIKit

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    enum RecorderError: Error {
        case permissionDenied
        case sessionConfigFailed(Error)
        case recorderInitFailed(Error)
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Live peak level in dBFS while recording. -160 means silence (mic likely disconnected
    /// or denied); typical speech sits between -30 and -5 dB.
    @Published private(set) var peakLevel: Float = -160

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedElapsed: TimeInterval = 0
    private var timer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        observeInterruptions()
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func start() async throws -> URL {
        try await requestPermission()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
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
        pausedElapsed = 0
        isRecording = true
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = true
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
        pausedAt = nil
        pausedElapsed = 0
        isRecording = false
        isPaused = false
        elapsed = 0
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            print("[AudioRecorder] saved \(url.lastPathComponent): \(size) bytes (~\(size / 32_000)s of expected audio)")
        }
        return url
    }

    // MARK: - Interruption handling

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in self.handleInterruption(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            guard isRecording, !isPaused, let recorder else { return }
            recorder.pause()
            // Freeze elapsed at the moment of pause so the timer doesn't keep ticking.
            if let started = startedAt {
                pausedElapsed = Date().timeIntervalSince(started)
                elapsed = pausedElapsed
            }
            pausedAt = Date()
            isPaused = true
            timer?.invalidate()
            timer = nil

        case .ended:
            guard isPaused, let recorder else { return }
            let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            // Only auto-resume if iOS thinks we should. If not (user took a long call etc.),
            // recording stays paused until the user taps to stop and process.
            guard options.contains(.shouldResume) else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("[AudioRecorder] failed to re-activate session after interruption: \(error)")
                return
            }
            // Shift startedAt forward by the paused duration so elapsed remains accurate.
            if let pAt = pausedAt {
                let pauseDur = Date().timeIntervalSince(pAt)
                startedAt = startedAt?.addingTimeInterval(pauseDur)
            }
            pausedAt = nil
            if recorder.record() {
                isPaused = false
                startTimer()
            }

        @unknown default:
            break
        }
    }

    // MARK: -

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startedAt, !self.isPaused else { return }
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
        // Record to NSTemporaryDirectory; SessionStore encrypts the file into the library
        // after recording stops. .completeFileProtectionUnlessOpen ensures writes succeed
        // even when the screen locks mid-recording.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParleyRecording", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("\(name).wav")
    }
}
