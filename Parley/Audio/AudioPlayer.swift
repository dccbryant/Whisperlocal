import AVFoundation
import Foundation

@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var url: URL?

    func load(_ url: URL) {
        if self.url == url, player != nil { return }
        stop()
        self.url = url
        configureSessionForPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = p.duration
            currentTime = 0
        } catch {
            print("[AudioPlayer] failed to load \(url.lastPathComponent): \(error)")
            player = nil
        }
    }

    func play() {
        guard let player else { return }
        configureSessionForPlayback()
        if player.play() {
            isPlaying = true
            startTimer()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(seconds, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    private func configureSessionForPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.timer?.invalidate()
            self.timer = nil
        }
    }
}
