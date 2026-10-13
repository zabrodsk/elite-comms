import Foundation

/// Session-local fingerprints. Embeddings and centroids never leave this process.
struct VoiceRegistry {
    static let similarityThreshold: Float = 0.72
    static let ambiguityMargin: Float = 0.04
    static let shortClipThreshold: Float = 0.55
    static let continuationThreshold: Float = 0.50
    static let acknowledgementThreshold: Float = 0.38
    static let clusterLimit = 64

    struct Voice {
        var centroid: [Float]
        var observations = 1
        var seconds: Double
        var label: String?
        var confidence: Double = 0
        var source: Segment.SpeakerSource?
        var manual = false
        var challenger: String?
        var challenges = 0
    }

    private(set) var voices: [Voice] = []

    mutating func identify(_ embedding: [Float]?, duration: Double = 3,
                          continuationVoice: Int? = nil, evidenceLabel: String? = nil,
                          briefAcknowledgement: Bool = false, delegateGreeting: Bool = false) -> (id: Int?, similarity: Float) {
        guard let embedding, let normalized = Self.normalized(embedding) else { return (nil, 0) }
        let scores = voices.enumerated().compactMap { index, voice -> (Int, Float)? in
            guard voice.centroid.count == normalized.count else { return nil }
            return (index, zip(voice.centroid, normalized).reduce(Float(0)) { $0 + $1.0 * $1.1 })
        }.sorted { $0.1 > $1.1 }
        if ProcessInfo.processInfo.environment["ELITE_DEBUG"] == "1" {
            print("VOICE_MATCH " + scores.prefix(4).map { String(format: "%d:%@=%.3f", $0.0, voices[$0.0].label ?? "?", $0.1) }.joined(separator: " "))
            fflush(stdout)
        }
        if let best = scores.first {
            let voice = voices[best.0]
            let shortClip = duration < 2.0
            // Subsecond acknowledgements contain little phonetic evidence. Only recall an
            // already named voice when it beats every alternative by a wide margin.
            let briefRecall = briefAcknowledgement && duration < 0.8 && voice.label != nil
            let continuesShortGreeting = best.0 == continuationVoice && voice.label != nil && voice.seconds < 2.0 && duration >= 2.0
            let threshold = briefRecall ? Self.acknowledgementThreshold : (continuesShortGreeting ? Self.continuationThreshold :
                (shortClip ? Self.shortClipThreshold : Self.similarityThreshold))
            let margin: Float = briefRecall ? 0.20 : (threshold < Self.similarityThreshold ? 0.15 : Self.ambiguityMargin)
            let conflict = !voice.manual && ((evidenceLabel != nil && voice.label != nil && evidenceLabel != voice.label && best.1 < 0.82) ||
                (delegateGreeting && voice.label == "Chair"))
            if best.1 >= threshold, !conflict {
                // Do not teach either centroid from audio that matches two speakers equally well.
                if scores.count > 1, best.1 - scores[1].1 < margin { return (nil, best.1) }
                var voice = voices[best.0]
                let weight = Float(min(voice.seconds, 30))
                let incoming = Float(max(0.3, min(duration, 10)))
                let mean = zip(voice.centroid, normalized).map { ($0 * weight + $1 * incoming) / (weight + incoming) }
                if let centroid = Self.normalized(mean) { voice.centroid = centroid }
                voice.observations += 1
                voice.seconds += max(0.3, duration)
                voices[best.0] = voice
                return (best.0, best.1)
            }
        }
        guard voices.count < Self.clusterLimit else { return (nil, scores.first?.1 ?? 0) }
        voices.append(Voice(centroid: normalized, seconds: max(0.3, duration)))
        return (voices.count - 1, 0)
    }

    @discardableResult
    mutating func teach(_ id: Int, label: String, confidence: Double, source: Segment.SpeakerSource) -> Bool {
        guard voices.indices.contains(id) else { return false }
        let old = voices[id]
        guard !old.manual || source == .manual else { return false }
        if source != .manual, old.label != label, confidence <= old.confidence + 0.02 {
            // Repeated strong self-reference can correct an earlier equally strong guess.
            // A floor announcement cannot rename an already recognized interjecting voice.
            guard source != .floor, confidence >= 0.85, confidence >= old.confidence - 0.05 else { return false }
            voices[id].challenges = old.challenger == label ? old.challenges + 1 : 1
            voices[id].challenger = label
            guard voices[id].challenges >= 2 else { return false }
        }
        voices[id].label = label
        voices[id].confidence = old.label == label ? max(old.confidence, confidence) : confidence
        voices[id].source = source
        voices[id].manual = source == .manual || old.manual
        voices[id].challenger = nil
        voices[id].challenges = 0
        return old.label != label || source == .manual
    }

    static func normalized(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-8 else { return nil }
        return values.map { $0 / norm }
    }
}
