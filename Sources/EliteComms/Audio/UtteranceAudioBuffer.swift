import AVFoundation
import CoreMedia

/// Owns a three-minute, 16 kHz mono ring on a serial worker queue. Input buffers are
/// the exact buffers yielded to SpeechAnalyzer, whose implicit timeline starts at zero.
final class UtteranceAudioBuffer: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private let queue = DispatchQueue(label: "elite-comms.utterance-audio", qos: .userInitiated)
    private let capacity = 180 * 16_000
    private var storage = [Float](repeating: 0, count: 180 * 16_000)
    private var written = 0
    private var inputFrames: Int64 = 0
    private var previousSample: Float = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        // Retain the immutable analyzer buffer; conversion and copying happen off the tap.
        queue.async { [self, buffer] in
            let frames = Int(buffer.frameLength)
            let rate = buffer.format.sampleRate
            guard frames > 0, rate > 0 else { return }
            let start = Double(inputFrames) / rate
            inputFrames += Int64(frames)
            let end = Int((Double(inputFrames) / rate * Self.sampleRate).rounded(.down))
            let channels = Int(buffer.format.channelCount)
            let stride = buffer.stride
            let interleaved = buffer.format.isInterleaved
            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            func mono(_ frame: Int) -> Float {
                if frame < 0 { return previousSample }
                let index = min(frame, frames - 1) * stride
                var value: Float = 0
                for channel in 0..<channels {
                    let dataChannel = interleaved ? 0 : channel
                    let offset = index + (interleaved ? channel : 0)
                    switch buffer.format.commonFormat {
                    case .pcmFormatFloat32: value += buffer.floatChannelData?[dataChannel][offset] ?? 0
                    case .pcmFormatFloat64: value += Float(buffers[dataChannel].mData?.assumingMemoryBound(to: Double.self)[offset] ?? 0)
                    case .pcmFormatInt16: value += Float(buffer.int16ChannelData?[dataChannel][offset] ?? 0) / 32768
                    case .pcmFormatInt32: value += Float(buffer.int32ChannelData?[dataChannel][offset] ?? 0) / 2147483648
                    default: break
                    }
                }
                return value / Float(max(channels, 1))
            }
            while written < end {
                let position = (Double(written) / Self.sampleRate - start) * rate
                let lower = Int(floor(position))
                let fraction = Float(position - Double(lower))
                storage[written % capacity] = mono(lower) * (1 - fraction) + mono(lower + 1) * fraction
                written += 1
            }
            previousSample = mono(frames - 1)
        }
    }

    func samples(in range: CMTimeRange) async -> [Float] {
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric else { return [] }
        let start = range.start.seconds
        let end = CMTimeRangeGetEnd(range).seconds
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return [] }
        let first = Int((start * Self.sampleRate).rounded(.down))
        let last = Int((end * Self.sampleRate).rounded(.up))
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard first >= max(0, written - capacity), last <= written + 1 else {
                    continuation.resume(returning: [])
                    return
                }
                let upper = min(last, written)
                continuation.resume(returning: (first..<upper).map { storage[$0 % capacity] })
            }
        }
    }
}
