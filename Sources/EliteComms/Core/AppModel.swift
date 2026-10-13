import AppKit
import CoreAudio
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Tab: Hashable { case live, notes, chat(UUID), brief }

    let settings = Settings()
    let codex = CodexClient.shared

    // Transcript
    var segments: [Segment] = []
    var volatileText = ""
    var level: Float = 0
    var status: LiveTranscriber.Status = .idle
    var sessionStart: Date?

    // Moments & AI
    var moments: [Moment] = []
    var notes = ""
    var notesBusy = false
    var notesUpdatedAt: Date?
    var chats: [ChatTab] = []
    var tab: Tab = .live
    var codexError: String?

    // Brief
    var briefDocs: [BriefStore.Doc] = []
    var myNotes = BriefStore.loadNotes()

    private let transcriber = LiveTranscriber()
    private var speakers = SpeakerTracker()
    private var notesCursor = 0
    private var cachedBrief = ""
    private var sessionFile: URL?

    var isListening: Bool { if case .listening = status { return true } else { return false } }
    var isActive: Bool {
        switch status {
        case .listening, .preparing, .downloading: return true
        default: return false
        }
    }

    var pendingMoments: [Moment] { moments.filter { $0.state != .dismissed } }

    init() {
        let first = ChatTab(title: "Copilot")
        chats = [first]
        reloadBrief()
        if !settings.isConfigured { tab = .brief }
        transcriber.onStatus = { [weak self] s in self?.status = s }
        transcriber.onVolatile = { [weak self] t in self?.volatileText = t }
        transcriber.onLevel = { [weak self] l in self?.level = l }
        transcriber.onFinal = { [weak self] text, conf, range in
            guard let self else { return }
            self.ingest(text, confidence: conf, embedding: self.transcriber.finalEmbedding,
                        audioStart: range.start.seconds, audioEnd: range.end.seconds)
        }
    }

    // MARK: Brief

    func reloadBrief() {
        briefDocs = BriefStore.documents()
        cachedBrief = BriefStore.fullBrief()
    }

    func saveMyNotes() {
        BriefStore.saveNotes(myNotes)
        reloadBrief()
    }

    func importBrief(_ urls: [URL]) {
        urls.forEach { BriefStore.importFile($0) }
        reloadBrief()
    }

    var systemPrompt: String { Prompts.system(settings: settings, brief: cachedBrief) }

    @discardableResult
    func requireDelegation() -> Bool {
        guard settings.isConfigured else {
            tab = .brief
            return false
        }
        return true
    }

    // MARK: Listening

    func toggleListening() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard requireDelegation() else { return }
        transcriber.prepareVoiceModels()
        if sessionStart == nil { sessionStart = Date() }
        if sessionFile == nil { sessionFile = newSessionFile() }
        let device = settings.inputDeviceID == 0 ? nil : AudioDeviceID(settings.inputDeviceID)
        Task { await transcriber.start(localeID: settings.localeID, vocabulary: BriefStore.vocabulary + [settings.country, settings.committee, settings.topic], deviceID: device) }
        warmUpCodex()
    }

    func stop() {
        Task { await transcriber.stop() }
        volatileText = ""
    }

    func newSession() {
        stop()
        segments.removeAll()
        moments.removeAll()
        notes = ""
        notesCursor = 0
        chats.forEach { $0.transcriptCursor = 0 }
        transcriber.discardPendingResults()
        speakers.reset()
        sessionStart = nil
        sessionFile = nil
    }

    func warmUpCodex() {
        Task {
            do { try await codex.ensureStarted(); codexError = nil }
            catch { codexError = error.localizedDescription }
        }
    }

    private func newSessionFile() -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let url = BriefStore.sessionsURL.appendingPathComponent("\(f.string(from: Date())) transcript.md")
        let header = "# elite-comms session: \(settings.committee)\nTopic: \(settings.topic)\n\n"
        try? header.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(toSession line: String) {
        guard let url = sessionFile, let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(Data((line + "\n").utf8))
        try? h.close()
    }

    /// Handles a finalized phrase from the recogniser.
    func ingest(_ text: String, confidence: Double?, embedding: [Float]? = nil,
                audioStart: Double? = nil, audioEnd: Double? = nil) {
        let tag = speakers.ingest(text, embedding: embedding, start: audioStart, end: audioEnd, selectedCountry: settings.shortCountry)
        var label = tag.label
        let floorToUs = tag.floorCountry != nil && tag.floorCountry == (Countries.canonicalLabel(settings.shortCountry) ?? Countries.canonical(in: settings.shortCountry) ?? settings.shortCountry)
        // Stronger evidence can correct a voice, including all of its earlier utterances.
        for index in segments.indices {
            guard let voiceID = segments[index].voiceID,
                  speakers.registry.voices.indices.contains(voiceID) else { continue }
            let voice = speakers.registry.voices[voiceID]
            if segments[index].speaker != voice.label || voice.manual {
                segments[index].speaker = voice.label
                segments[index].speakerSource = voice.manual ? .manual : .voice
            }
        }
        var seg = Segment(date: Date(), text: text, speaker: label, voiceID: tag.voiceID,
                          speakerSource: tag.source, confidence: confidence)
        switch DelegationDetector.check(text, country: settings.country) {
        case .directed: seg.hit = .directed
        case .mention: seg.hit = .mention
        case .none: break
        }

        // Our own delegate talking (their voice, "The delegation of Australia believes…", or reading one of our
        // drafts aloud) must never trigger a reply to themselves.
        let us = Countries.canonicalLabel(settings.shortCountry) ?? Countries.canonical(in: settings.shortCountry) ?? settings.shortCountry
        let readingDraft = SelfSpeech.isReadingDraft(text, moments: moments)
        // Without a fingerprint, a carried-over floor label is too weak to dismiss a new question.
        if seg.hit == .directed, seg.speaker == us, seg.voiceID == nil, seg.speakerSource == .floor,
           !readingDraft, !SelfSpeech.soundsLikeUs(text, country: settings.shortCountry) {
            seg.speaker = nil
            seg.speakerSource = nil
            label = nil
        }
        if seg.speaker == us || readingDraft || SelfSpeech.soundsLikeUs(text, country: settings.shortCountry) {
            seg.hit = .none
            if seg.speaker == nil || seg.speakerSource == .voice || readingDraft {
                seg.speaker = us
                seg.speakerSource = .selfReference
            }
            // Reading our draft is strong evidence: learn this voice as ours so later lines are recognised.
            if readingDraft, let v = seg.voiceID, speakers.registry.voices.indices.contains(v),
               speakers.registry.voices[v].label != us, !speakers.registry.voices[v].manual {
                speakers.learnOwnVoice(v, as: us)
                for i in segments.indices where segments[i].voiceID == v {
                    segments[i].speaker = us
                    segments[i].speakerSource = .selfReference
                }
            }
        }

        // Merge short fragments from the same speaker into the previous line for readability.
        if let last = segments.last, last.speaker == seg.speaker, last.voiceID == seg.voiceID,
           last.speakerSource != .manual || seg.speakerSource == .manual,
           seg.hit == .none, last.hit == .none,
           seg.date.timeIntervalSince(last.date) < 6, last.text.count < 280 {
            segments[segments.count - 1].text += " " + text
        } else {
            segments.append(seg)
        }
        append(toSession: seg.line)
        Self.log("SEG \(seg.hit) voice=\(seg.voiceID.map(String.init) ?? "-") src=\(seg.speakerSource?.rawValue ?? "-") \(seg.line)")

        // The recogniser sometimes splits one sentence ("…the delegate of Australia." / "You have the floor.").
        // Look at this line together with the previous line from the same speaker.
        let prev = segments.count >= 2 ? segments[segments.count - 2] : nil
        let joined = (prev.map { $0.speaker == seg.speaker && seg.date.timeIntervalSince($0.date) < 8 ? $0.text + " " : "" } ?? "") + text
        let floorSplit = seg.speaker == "Chair" && Self.floorPattern(us).firstMatch(
            in: joined, range: NSRange(location: 0, length: (joined as NSString).length)) != nil

        if floorToUs || floorSplit {
            moments.removeAll { $0.kind == .mention && $0.state == .pending && $0.speaker == "Chair" && seg.date.timeIntervalSince($0.createdAt) < 10 }
            addMoment(Moment(kind: .floor, quote: joined, speaker: "Chair", why: "The chair called on you", urgency: "high"),
                      autoRun: settings.autoDraft)
        } else if seg.hit == .directed {
            // Fold a just-created "mention" from the same speaker into this question ("Question to Australia." + "Why…?").
            var quote = joined
            if let m = moments.first, m.kind == .mention, m.state == .pending, m.speaker == label,
               Date().timeIntervalSince(m.createdAt) < 10 {
                if !quote.contains(m.quote) { quote = m.quote + " " + text }
                moments.removeFirst()
            }
            addMoment(Moment(kind: .directed, quote: quote, speaker: label, why: "Question or challenge addressed to you", urgency: "high"),
                      autoRun: settings.autoDraft)
        } else if seg.hit == .mention && seg.speaker != "Chair" {
            addMoment(Moment(kind: .mention, quote: text, speaker: label, why: nil, urgency: "medium"), autoRun: false)
        }
    }

    private static func floorPattern(_ country: String) -> NSRegularExpression {
        let c = NSRegularExpression.escapedPattern(for: country.lowercased())
        return try! NSRegularExpression(
            pattern: #"(?:delegate|delegation)\s+of\s+(?:the\s+)?\#(c)\b[^.?!]{0,20}[.,]?\s*(?:you\s+(?:now\s+)?have\s+the\s+floor|the\s+floor\s+is\s+yours)|recogni[sz]es?\s+(?:the\s+)?(?:delegate|delegation)\s+of\s+(?:the\s+)?\#(c)\b"#,
            options: [.caseInsensitive])
    }

    /// A correction teaches the fingerprint, unless this phrase has no usable audio.
    func relabel(segmentID: UUID, as label: String) {
        guard let canonical = Countries.canonicalLabel(label),
              let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        if let voiceID = segments[index].voiceID {
            speakers.relabel(voiceID: voiceID, as: canonical)
            for index in segments.indices where segments[index].voiceID == voiceID {
                segments[index].speaker = canonical
                segments[index].speakerSource = .manual
            }
            append(toSession: "[Speaker correction] voice=\(voiceID) label=\(canonical) src=manual")
        } else {
            segments[index].speaker = canonical
            segments[index].speakerSource = .manual
            append(toSession: "[Speaker correction] segment=\(segmentID) label=\(canonical) src=manual")
        }
    }

    var knownSpeakers: [String] {
        Set(segments.compactMap(\.speaker)).sorted {
            if $0 == "Chair" { return $1 != "Chair" }
            if $1 == "Chair" { return false }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func transcriptWindow(seconds: TimeInterval = 180, maxChars: Int = 6000) -> String {
        let cutoff = Date().addingTimeInterval(-seconds)
        let lines = segments.filter { $0.date >= cutoff }.map(\.line)
        let text = (lines.isEmpty ? segments.suffix(12).map(\.line) : lines).joined(separator: "\n")
        return String(text.suffix(maxChars))
    }

    func transcriptSince(_ index: Int, maxChars: Int = 12000) -> String {
        guard index < segments.count else { return "" }
        return String(segments[index...].map(\.line).joined(separator: "\n").suffix(maxChars))
    }

    // MARK: Moments

    private func addMoment(_ m: Moment, autoRun: Bool) {
        let key = Self.normalize(m.quote)
        if let existing = moments.first(where: { $0.state != .dismissed && Self.overlap(Self.normalize($0.quote), key) > 0.6 }) {
            // A plain mention later confirmed as aimed at us: upgrade it to a directed moment.
            guard existing.kind == .mention, m.kind == .directed, existing.state == .pending else { return }
            moments.removeAll { $0.id == existing.id }
        } else if moments.contains(where: { Self.overlap(Self.normalize($0.quote), key) > 0.6 }) {
            return
        }
        moments.insert(m, at: 0)
        Self.log("MOMENT \(m.kind) [\(m.speaker ?? "-")] \(m.quote) — \(m.why ?? "")")
        if moments.count > 40 { moments.removeLast(moments.count - 40) }
        if m.kind == .floor || m.kind == .directed { NSSound(named: "Tink")?.play() }
        if autoRun { run(m, action: m.kind == .factCheck ? .factCheck : .draft) }
    }

    func dismiss(_ m: Moment) {
        m.task?.cancel()
        m.state = .dismissed
    }

    func run(_ m: Moment, action: Moment.Action) {
        guard requireDelegation() else { return }
        m.task?.cancel()
        m.action = action
        m.state = .working
        m.output = ""
        m.status = action == .factCheck ? "Checking sources…" : "Drafting…"
        let country = settings.shortCountry
        let prompt = action == .factCheck
            ? Prompts.factCheck(claim: m.quote, speaker: m.speaker, transcript: transcriptWindow(seconds: 120), country: country)
            : Prompts.draft(kind: m.kind, quote: m.quote, speaker: m.speaker, transcript: transcriptWindow(), country: country)
        let (model, effort) = settings.route(action == .factCheck ? .factCheck : .draft)
        let system = systemPrompt
        m.task = Task { [weak m] in
            do {
                let final = try await codex.oneShot(model: model, instructions: system, prompt: prompt, effort: effort) { ev in
                    Task { @MainActor in
                        guard let m else { return }
                        switch ev {
                        case .status(let s): m.status = s.count > 80 ? String(s.prefix(80)) + "…" : s
                        case .delta(let d): m.output += d; m.status = ""
                        }
                    }
                }
                guard let m else { return }
                if m.output.isEmpty { m.output = final }
                m.status = ""
                m.state = .done
                Self.log("OUTPUT \(m.kind)/\(action):\n\(m.output)")
            } catch is CancellationError {
            } catch {
                Self.log("FAILED \(error.localizedDescription)")
                m?.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Notes

    func refreshNotes() {
        guard requireDelegation() else { return }
        guard !notesBusy, notesCursor < segments.count else { return }
        notesBusy = true
        let delta = transcriptSince(notesCursor, maxChars: 14000)
        notesCursor = segments.count
        let prompt = Prompts.notes(transcript: delta, previous: notes, country: settings.shortCountry)
        let (model, effort) = settings.route(.notes)
        let system = systemPrompt
        Task {
            defer { notesBusy = false }
            if let out = try? await codex.oneShot(model: model, instructions: system, prompt: prompt, effort: effort), !out.isEmpty {
                notes = out
                notesUpdatedAt = Date()
                Self.log("NOTES\n\(out)")
            }
        }
    }

    // MARK: Chat

    @discardableResult
    func newChat(title: String? = nil) -> ChatTab {
        let t = ChatTab(title: title ?? "Chat \(chats.count + 1)")
        chats.append(t)
        tab = .chat(t.id)
        return t
    }

    func closeChat(_ t: ChatTab) {
        t.task?.cancel()
        if let tid = t.threadId { codex.forget(threadId: tid) }
        chats.removeAll { $0.id == t.id }
        if chats.isEmpty { chats = [ChatTab(title: "Copilot")] }
        if case .chat(let id) = tab, id == t.id { tab = .chat(chats[0].id) }
    }

    func chat(_ id: UUID) -> ChatTab? { chats.first { $0.id == id } }

    func send(_ text: String, in tab: ChatTab) {
        guard requireDelegation() else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !tab.busy else { return }
        if tab.messages.isEmpty, tab.title.hasPrefix("Chat ") {
            tab.title = String(message.prefix(22))
        }
        tab.messages.append(ChatMessage(role: .user, text: message))
        let reply = ChatMessage(role: .assistant, text: "", streaming: true)
        reply.status = "Thinking…"
        tab.messages.append(reply)
        tab.busy = true

        let context = systemPrompt
        if tab.contextKey != context {
            if let tid = tab.threadId { codex.forget(threadId: tid) }
            tab.threadId = nil
            tab.transcriptCursor = 0
            tab.contextKey = context
        }
        let delta = transcriptSince(tab.transcriptCursor)
        tab.transcriptCursor = segments.count
        let prompt = Prompts.chatTurn(transcriptDelta: delta, message: message)
        let (model, effort) = settings.route(.chat)
        let system = systemPrompt

        tab.task = Task { [weak tab] in
            defer { tab?.busy = false; reply.streaming = false }
            do {
                guard let tab else { return }
                if tab.threadId == nil {
                    tab.threadId = try await codex.startThread(model: model, instructions: system)
                }
                let final = try await codex.runTurn(threadId: tab.threadId!, text: prompt, effort: effort) { ev in
                    Task { @MainActor in
                        switch ev {
                        case .status(let s): reply.status = s.count > 80 ? String(s.prefix(80)) + "…" : s
                        case .delta(let d): reply.text += d; reply.status = ""
                        }
                    }
                }
                if reply.text.isEmpty { reply.text = final }
                reply.status = ""
            } catch is CancellationError {
                reply.status = ""
                if reply.text.isEmpty { reply.text = "_Stopped._" }
            } catch {
                reply.status = ""
                reply.error = error.localizedDescription
                tab?.threadId = nil
            }
        }
    }

    func stopChat(_ tab: ChatTab) { tab.task?.cancel() }

    /// "Ask about this" from a transcript line or moment.
    func ask(about quote: String, question: String) {
        let t: ChatTab
        if case .chat(let id) = tab, let c = chat(id) { t = c } else { t = chats[0]; tab = .chat(t.id) }
        send("\(question)\n\n> \(quote)", in: t)
    }

    // MARK: Utils

    static let debug = ProcessInfo.processInfo.environment["ELITE_DEBUG"] == "1"
    static func log(_ s: String) {
        guard debug else { return }
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(s)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func normalize(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        // Very short lines ("Question to the delegate of Australia.") share words with everything; don't call them duplicates.
        guard min(a.count, b.count) >= 4 else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    static func extractJSON(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return nil }
        let s = String(raw[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    var exportTranscript: String { segments.map(\.line).joined(separator: "\n") }
}
