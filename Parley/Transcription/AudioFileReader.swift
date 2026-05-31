import AVFoundation
import Foundation

enum AudioFileReader {
    enum ReadError: Error {
        case openFailed(Error)
        case formatUnavailable
        case readFailed(Error)
    }

    /// Returns the duration in seconds of any AVFoundation-readable audio file, or nil if
    /// the file can't be opened.
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    /// Read any AVFoundation-readable audio file and return 16 kHz mono Float32 samples
    /// normalized to [-1, 1] — the exact shape WhisperKit's `transcribe(audioArray:)` wants.
    static func readMono16kFloats(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ReadError.openFailed(error)
        }

        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw ReadError.formatUnavailable
        }

        // Fast path: source already 16 kHz mono float — read straight into a single buffer.
        if inFormat.sampleRate == 16_000, inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32 {
            let frames = AVAudioFrameCount(file.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
                throw ReadError.formatUnavailable
            }
            do { try file.read(into: buf) } catch { throw ReadError.readFailed(error) }
            guard let ptr = buf.floatChannelData?.pointee else { return [] }
            return Array(UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
        }

        // Slow path: convert (e.g. 44.1 kHz Int16 → 16 kHz Float32 mono).
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ReadError.formatUnavailable
        }
        let chunk: AVAudioFrameCount = 8_192
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else {
            throw ReadError.formatUnavailable
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * 16_000 / inFormat.sampleRate))

        while true {
            let outCapacity = AVAudioFrameCount(Double(chunk) * 16_000 / inFormat.sampleRate) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { break }
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, inStatus in
                do {
                    try file.read(into: inBuf)
                } catch {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                inStatus.pointee = .haveData
                return inBuf
            }
            if let ptr = outBuf.floatChannelData?.pointee, outBuf.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return samples
    }
}
