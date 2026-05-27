import AVFoundation
import Foundation

enum AudioDecoder {
    enum DecoderError: Error {
        case openFailed(Error)
        case converterUnavailable
        case conversionFailed(Error?)
        case allocationFailed
    }

    /// Decode any AVFoundation-readable audio file to 16 kHz mono Float32 PCM (the format
    /// whisper.cpp expects). Returns the samples as a contiguous Float array.
    static func decodeToPCM16k(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DecoderError.openFailed(error)
        }

        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw DecoderError.allocationFailed
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw DecoderError.converterUnavailable
        }

        let chunkFrames: AVAudioFrameCount = 8_192
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames) else {
            throw DecoderError.allocationFailed
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length) * 16_000 / Int(inFormat.sampleRate))

        var sawEndOfStream = false
        while !sawEndOfStream {
            let outCapacity = AVAudioFrameCount(Double(chunkFrames) * 16_000.0 / inFormat.sampleRate) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
                throw DecoderError.allocationFailed
            }

            var conversionError: NSError?
            let status = converter.convert(to: outBuf, error: &conversionError) { _, inputStatus in
                do {
                    try file.read(into: inBuf)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuf
            }

            switch status {
            case .haveData:
                if let ptr = outBuf.floatChannelData?.pointee {
                    samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
                }
            case .inputRanDry:
                if let ptr = outBuf.floatChannelData?.pointee {
                    samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
                }
            case .endOfStream:
                if let ptr = outBuf.floatChannelData?.pointee, outBuf.frameLength > 0 {
                    samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
                }
                sawEndOfStream = true
            case .error:
                throw DecoderError.conversionFailed(conversionError)
            @unknown default:
                sawEndOfStream = true
            }
        }

        return samples
    }
}
