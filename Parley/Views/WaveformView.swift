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
        let computed = await WaveformModel.computePeaks(url: url, buckets: buckets)
        peaks = computed
        isLoading = false
    }

    /// Compute waveform peaks using AVAssetReader. AVAudioFile is stricter about formats than
    /// AVAudioPlayer — some compressed m4a/mp3 files open in the player but not the file reader,
    /// which is why imported recordings could play yet show an empty waveform. AVAssetReader
    /// runs through the same decoding pipeline as playback, so anything that plays will render.
    nonisolated private static func computePeaks(url: URL, buckets: Int) async -> [Float] {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first, buckets > 0 else { return [] }

            let (duration, formatDescriptions) = try await (
                asset.load(.duration),
                track.load(.formatDescriptions)
            )

            // Request decoded mono Float32 PCM so we don't have to deal with interleaving.
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
            ]

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }

            let sampleRate: Double = {
                guard let cmFormat = formatDescriptions.first as? CMAudioFormatDescription,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cmFormat) else {
                    return 44_100
                }
                return asbd.pointee.mSampleRate
            }()

            let totalSeconds = CMTimeGetSeconds(duration)
            let totalFrames = Int(totalSeconds * sampleRate)
            guard totalFrames > 0 else { return [] }
            let perBucket = max(1, totalFrames / buckets)

            var out: [Float] = []
            out.reserveCapacity(buckets)
            var bucketRemaining = perBucket
            var currentPeak: Float = 0

            while reader.status == .reading, out.count < buckets {
                guard let sampleBuffer = output.copyNextSampleBuffer(),
                      let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                    break
                }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length > 0 else { continue }
                var data = Data(count: length)
                _ = data.withUnsafeMutableBytes { rawPtr -> OSStatus in
                    guard let base = rawPtr.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
                }
                data.withUnsafeBytes { rawPtr in
                    let floats = rawPtr.bindMemory(to: Float.self)
                    let count = length / MemoryLayout<Float>.size
                    for i in 0..<count {
                        let v = abs(floats[i])
                        if v > currentPeak { currentPeak = v }
                        bucketRemaining -= 1
                        if bucketRemaining <= 0 {
                            out.append(currentPeak)
                            currentPeak = 0
                            bucketRemaining = perBucket
                            if out.count >= buckets { return }
                        }
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
        } catch {
            return []
        }
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
