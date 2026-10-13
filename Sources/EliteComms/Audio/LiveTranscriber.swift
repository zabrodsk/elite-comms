import AVFoundation
import CoreAudio
import Speech

/// On-device live transcription with Apple's SpeechAnalyzer + SpeechTranscriber.
/// Emits volatile (in-flight) text continuously and finalized phrases as they settle.
@MainActor
final class LiveTranscriber {
    enum Status: Equatable {
        case idle
        case preparing(String)
        case downloading(Double)
        case listening
        case failed(String)
    }

    var onStatus: ((Status) -> Void)?
    var onVolatile: ((String) -> Void)?
    var onFinal: ((String, Double?, CMTimeRange) -> Void)?   // text, confidence, analyzer range
    var onLevel: ((Float) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var mic: MicCapture?
    private var feeder: FileFeeder?
    static var testAudioURL: URL? {
        ProcessInfo.processInfo.environment["ELITE_TEST_AUDIO"].map { URL(fileURLWithPath: $0) }
    }
    private var resultsTask: Task<Void, Never>?
    private var running = false
    private let voiceModels = VoiceEmbeddingService()
    private var voiceWarmup: Task<Void, Never>?
    private var resultGeneration = UUID()
    private(set) var finalEmbedding: [Float]?
    private(set) var voiceModelStatus = "Voice models not loaded"

    init() { prepareVoiceModels() }

    func prepareVoiceModels() {
        guard voiceWarmup == nil else { return }
        let service = voiceModels
        voiceWarmup = Task { [weak self] in
            await service.prepare { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    if self.voiceModelStatus != message {
                        self.voiceModelStatus = message
                        if ProcessInfo.processInfo.environment["ELITE_DEBUG"] == "1" {
                            print("VOICE \(message)")
                            fflush(stdout)
                        }
                    }
                }
            }
            self?.voiceWarmup = nil
        }
    }

    func discardPendingResults() {
        resultGeneration = UUID()
        finalEmbedding = nil
    }

    func start(localeID: String, vocabulary: [String], deviceID: AudioDeviceID?) async {
        guard !running else { return }
        running = true
        discardPendingResults()
        let generation = resultGeneration
        let utteranceAudio = UtteranceAudioBuffer()
        onStatus?(.preparing("Checking microphone…"))
        let micOK = Self.testAudioURL != nil ? true : await MicCapture.requestPermission()
        guard micOK else {
            fail("Microphone access denied. Enable elite-comms in System Settings → Privacy & Security → Microphone.")
            return
        }
        guard SpeechTranscriber.isAvailable else {
            fail("On-device SpeechTranscriber isn't available on this Mac.")
            return
        }
        do {
            onStatus?(.preparing("Loading English speech model…"))
            let requested = Locale(identifier: localeID)
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                fail("Locale \(localeID) isn't supported for on-device transcription.")
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.transcriptionConfidence]
            )
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let progress = req.progress
                let poll = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        self?.onStatus?(.downloading(progress.fractionCompleted))
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                try await req.downloadAndInstall()
                poll.cancel()
            }
            guard running else { return }

            let analyzer = SpeechAnalyzer(modules: [transcriber],
                                          options: .init(priority: .userInitiated, modelRetention: .processLifetime))
            if !vocabulary.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings[.general] = Array(vocabulary.prefix(300))
                try? await analyzer.setContext(ctx)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                fail("No compatible audio format for the speech model.")
                return
            }
            try await analyzer.prepareToAnalyze(in: format)
            self.analyzer = analyzer

            resultsTask = Task { @MainActor [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters)
                        if result.isFinal {
                            let conf = Self.meanConfidence(result.text)
                            self.onVolatile?("")
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                let samples = await utteranceAudio.samples(in: result.range)
                                if ProcessInfo.processInfo.environment["ELITE_DEBUG"] == "1" {
                                    print(String(format: "VOICE_AUDIO start=%.3f end=%.3f samples=%d", result.range.start.seconds, result.range.end.seconds, samples.count))
                                    fflush(stdout)
                                }
                                let embedding = await self.voiceModels.embedding(for: samples)
                                guard !Task.isCancelled, self.resultGeneration == generation else { return }
                                self.finalEmbedding = embedding
                                self.onFinal?(trimmed, conf, result.range)
                            }
                        } else {
                            self.onVolatile?(text)
                        }
                    }
                } catch {
                    if self?.running == true { self?.fail("Transcriber stopped: \(error.localizedDescription)") }
                }
            }

            let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            if let url = Self.testAudioURL {
                let f = FileFeeder()
                f.speed = Double(ProcessInfo.processInfo.environment["ELITE_TEST_SPEED"] ?? "1") ?? 1
                f.onLevel = { [weak self] l in Task { @MainActor in self?.onLevel?(l) } }
                try f.start(url: url, analyzerFormat: format, continuation: cont, utteranceAudio: utteranceAudio)
                self.feeder = f
            } else {
                let mic = MicCapture()
                mic.onLevel = { [weak self] l in Task { @MainActor in self?.onLevel?(l) } }
                try mic.start(deviceID: deviceID, analyzerFormat: format, continuation: cont, utteranceAudio: utteranceAudio)
                self.mic = mic
            }
            try await analyzer.start(inputSequence: stream)
            onStatus?(.listening)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard running else { return }
        running = false
        mic?.stop()
        mic = nil
        feeder?.stop()
        feeder = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
        onLevel?(0)
        onStatus?(.idle)
    }

    private func fail(_ message: String) {
        running = false
        mic?.stop()
        mic = nil
        feeder?.stop()
        feeder = nil
        if let a = analyzer { Task { await a.cancelAndFinishNow() } }
        analyzer = nil
        onStatus?(.failed(message))
    }

    private static func meanConfidence(_ s: AttributedString) -> Double? {
        var total = 0.0, n = 0.0
        for run in s.runs {
            if let c = run.transcriptionConfidence {
                let w = Double(s[run.range].characters.count)
                total += c * w; n += w
            }
        }
        return n > 0 ? total / n : nil
    }
}
