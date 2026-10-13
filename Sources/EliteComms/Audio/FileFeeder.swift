import AVFoundation
import Speech

/// Test/demo source: plays an audio file into the analyzer at real-time pace (set ELITE_TEST_AUDIO=/path/file).
final class FileFeeder: @unchecked Sendable {
    private var task: Task<Void, Never>?
    var onLevel: (@Sendable (Float) -> Void)?
    var speed: Double = 1

    func start(url: URL, analyzerFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
               utteranceAudio: UtteranceAudioBuffer) throws {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: inFormat, to: analyzerFormat) else {
            throw NSError(domain: "elite-comms", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't convert test audio"])
        }
        converter.primeMethod = .none
        let chunk = AVAudioFrameCount(inFormat.sampleRate * 0.1)
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { break }
                do { try file.read(into: buf, frameCount: chunk) } catch { break }
                if buf.frameLength == 0 { break }
                if let ch = buf.floatChannelData?[0] {
                    var sum: Float = 0
                    for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
                    let db = 20 * log10(max(sqrt(sum / Float(buf.frameLength)), 1e-6))
                    self?.onLevel?(max(0, min(1, (db + 55) / 45)))
                }
                let cap = AVAudioFrameCount(Double(buf.frameLength) * analyzerFormat.sampleRate / inFormat.sampleRate + 32)
                guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: cap) else { break }
                var fed = false
                _ = converter.convert(to: out, error: nil) { _, st in
                    if fed { st.pointee = .noDataNow; return nil }
                    fed = true; st.pointee = .haveData; return buf
                }
                if out.frameLength > 0 {
                    utteranceAudio.append(out)
                    continuation.yield(AnalyzerInput(buffer: out))
                }
                try? await Task.sleep(for: .milliseconds(Int(100 / (self?.speed ?? 1))))
            }
            // Pad with a little silence so the last phrase finalizes.
            if !Task.isCancelled, let silence = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: AVAudioFrameCount(analyzerFormat.sampleRate * 2)) {
                silence.frameLength = silence.frameCapacity
                for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                utteranceAudio.append(silence)
                continuation.yield(AnalyzerInput(buffer: silence))
            }
            continuation.finish()
        }
    }

    func stop() { task?.cancel() }
}
