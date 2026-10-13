import CoreML
import FluidAudio
import Foundation

/// CoreML loading and inference are isolated from the main actor and audio tap.
actor VoiceEmbeddingService {
    private var diarizer: DiarizerManager?
    private var preparing = false
    private(set) var status = "Voice models not loaded"

    func prepare(report: @escaping @Sendable (String) -> Void) async {
        guard diarizer == nil, !preparing else { return }
        preparing = true
        defer { preparing = false }
        status = "Downloading and loading voice models"
        report(status)
        let began = Date()
        let directory = DiarizerModels.defaultModelsDirectory()
        let before = Self.byteCount(in: directory)
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try await DiarizerModels.downloadIfNeeded(configuration: configuration) { progress in
                let message: String
                switch progress.phase {
                case .listing: message = "Checking voice model downloads"
                case .downloading: message = "Downloading voice models: \(Int(progress.fractionCompleted * 100))%"
                case .compiling(let name): message = "Loading voice model \(name)"
                }
                report(message)
            }
            let manager = DiarizerManager()
            manager.initialize(models: models)
            diarizer = manager
            let size = Self.byteCount(in: directory)
            status = String(format: "Voice models ready: bytes=%lld downloadedBytes=%lld loadSeconds=%.2f",
                            size, max(0, size - before), Date().timeIntervalSince(began))
            report(status)
        } catch {
            status = "Voice models unavailable; using text-only tagging: \(error.localizedDescription)"
            report(status)
        }
    }

    func embedding(for samples: [Float]) -> [Float]? {
        // First-use downloads never hold up transcription. Text evidence works meanwhile.
        guard let diarizer, samples.count >= 5_120 else { return nil }
        // Trim quiet edges, leaving a small amount of context. Do not introduce samples
        // outside the recognizer's range, which could include a different speaker.
        let frame = 320
        let blocks = stride(from: 0, to: samples.count, by: frame).filter { start in
            let end = min(start + frame, samples.count)
            let energy = samples[start..<end].reduce(Float(0)) { $0 + $1 * $1 }
            return sqrt(energy / Float(end - start)) > 0.005
        }
        guard let first = blocks.first, let last = blocks.last else { return nil }
        let audio = Array(samples[max(0, first - frame)..<min(samples.count, last + 2 * frame)])
        guard audio.count >= 5_120 else { return nil }
        do {
            var embeddings: [[Float]] = []
            // FluidAudio's WeSpeaker input is exactly 160,000 samples. Split long phrases
            // instead of passing an oversized waveform to its fixed-size buffers.
            for start in stride(from: 0, to: audio.count, by: 160_000) {
                let chunk = Array(audio[start..<min(start + 160_000, audio.count)])
                guard chunk.count >= 5_120 else { continue }
                let embedding = try diarizer.extractSpeakerEmbedding(from: chunk)
                if let normalized = VoiceRegistry.normalized(embedding) { embeddings.append(normalized) }
            }
            guard let first = embeddings.first else { return nil }
            let mean = embeddings.dropFirst().reduce(first) { sum, next in zip(sum, next).map(+) }
            return VoiceRegistry.normalized(mean)
        } catch {
            if ProcessInfo.processInfo.environment["ELITE_DEBUG"] == "1" {
                print("VOICE embedding unavailable; using text evidence: \(error.localizedDescription)")
                fflush(stdout)
            }
            return nil
        }
    }

    private static func byteCount(in directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(Int64(0)) { sum, url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { return sum }
            return sum + Int64(values.fileSize ?? 0)
        }
    }
}
