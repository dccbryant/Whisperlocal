import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class WaveformModel: ObservableObject {
    @Published private(set) var peaks: [Float] = []
    @Published private(set) var isLoading = false

    private var loadedURL: URL?

    func load(_ url: URL, buckets: Int = 200) async {
        if loadedURL == url, !peaks.isEmpty { return }
        loadedURL = url
        isLoading = true
        let computed = await Task.detached(priority: .userInitiated) {
            WaveformModel.computePeaks(url: url, buckets: buckets)
        }.value
        peaks = computed
        isLoading = false
    }

    nonisolated private static func computePeaks(url: URL, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        guard totalFrames > 0, buckets > 0 else { return [] }

        // Stream the file rather than allocating one buffer at full length — a 30-minute
        // 44.1 kHz file would need ~300 MB up front, which silently fails to allocate and
        // leaves the waveform empty. Pull 64 K frames at a time and roll the bucket peaks
        // forward as we go.
        let chunkCapacity: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
            return []
        }
        let perBucket = max(1, totalFrames / buckets)
        var out: [Float] = []
        out.reserveCapacity(buckets)
        var bucketRemaining = perBucket
        var currentPeak: Float = 0

        while out.count < buckets {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let framesRead = Int(buffer.frameLength)
            if framesRead == 0 { break }
            guard let channel = buffer.floatChannelData?.pointee else { break }
            for i in 0..<framesRead {
                let v = abs(channel[i])
                if v > currentPeak { currentPeak = v }
                bucketRemaining -= 1
                if bucketRemaining <= 0 {
                    out.append(currentPeak)
                    currentPeak = 0
                    bucketRemaining = perBucket
                    if out.count >= buckets { break }
                }
            }
        }
        // Flush any partial trailing bucket so very short files still render something.
        if out.count < buckets, currentPeak > 0 {
            out.append(currentPeak)
        }
        if let maxPeak = out.max(), maxPeak > 0 {
            out = out.map { $0 / maxPeak }
        }
        return out
    }
}

/// Renders a waveform of the audio file. While playing, the bars before the current playback
/// position get the accent color; the rest fade to the divider color.
struct WaveformView: View {
    let url: URL
    /// 0...1 fraction of playback progress; bars before this point are highlighted.
    let progress: Double
    /// Tap callback returning a 0...1 fraction along the bar to seek to.
    var onSeek: (Double) -> Void = { _ in }

    @StateObject private var model = WaveformModel()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if model.peaks.isEmpty && model.isLoading {
                    // Subtle placeholder while reading the file.
                    Rectangle().fill(BraunPalette.divider.opacity(0.3))
                } else if !model.peaks.isEmpty {
                    bars(in: geo.size)
                } else {
                    Rectangle().fill(.clear)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onEnded { v in
                    let pct = max(0, min(1, v.location.x / geo.size.width))
                    onSeek(pct)
                }
            )
        }
        .task(id: url) { await model.load(url) }
    }

    private func bars(in size: CGSize) -> some View {
        let allPeaks = model.peaks
        // Adapt the bar count to whatever fits: aim for at least 3pt per bar so they're
        // visible without overflowing the container.
        let spacing: CGFloat = 1
        let targetCount = max(20, min(allPeaks.count, Int(size.width / 3)))
        let peaks: [Float] = {
            if targetCount >= allPeaks.count { return allPeaks }
            let step = Double(allPeaks.count) / Double(targetCount)
            return (0..<targetCount).map { i in
                let start = Int(Double(i) * step)
                let end = min(allPeaks.count, max(start + 1, Int(Double(i + 1) * step)))
                return allPeaks[start..<end].max() ?? 0
            }
        }()
        let count = peaks.count
        let barWidth = max(1, (size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let cutoff = Int(Double(count) * max(0, min(1, progress)))
        return HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                let peak = peaks[i]
                let h = max(2, CGFloat(peak) * size.height)
                Capsule()
                    .fill(i < cutoff ? BraunPalette.foreground : BraunPalette.divider)
                    .frame(width: barWidth, height: h)
            }
        }
        .frame(width: size.width, alignment: .leading)
    }
}
