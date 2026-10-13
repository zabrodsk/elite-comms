import Foundation
import Observation

struct Segment: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    var text: String
    var speaker: String?
    var voiceID: Int? = nil
    var speakerSource: SpeakerSource? = nil
    var confidence: Double?
    var hit: Hit = .none

    enum Hit: Equatable { case none, mention, directed }
    enum SpeakerSource: String, Equatable { case chairPhrase, floor, selfReference, voice, manual }

    var line: String {
        "[\(date.formatted(date: .omitted, time: .standard))] \(speaker.map { "\($0): " } ?? "")\(text)"
    }
}

@Observable
final class Moment: Identifiable {
    enum Kind: String {
        case floor, directed, mention, factCheck, opportunity, help, hitBack, speech

        var label: String {
            switch self {
            case .floor: return "You have the floor"
            case .directed: return "Aimed at you"
            case .mention: return "You were mentioned"
            case .factCheck: return "Fact-check"
            case .opportunity: return "Opening"
            case .help: return "Your answer"
            case .hitBack: return "Hit back"
            case .speech: return "Your speech"
            }
        }
    }

    enum State: Equatable { case pending, working, done, failed(String), dismissed }
    enum Action: Equatable { case draft, factCheck }

    let id = UUID()
    let kind: Kind
    let quote: String
    let speaker: String?
    let why: String?
    let urgency: String
    let createdAt = Date()
    var state: State = .pending
    var action: Action?
    var output = ""
    var status = ""
    var task: Task<Void, Never>?

    init(kind: Kind, quote: String, speaker: String?, why: String?, urgency: String = "medium") {
        self.kind = kind
        self.quote = quote
        self.speaker = speaker
        self.why = why
        self.urgency = urgency
    }
}

@Observable
final class ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var status = ""
    var streaming = false
    var error: String?

    init(role: Role, text: String, streaming: Bool = false) {
        self.role = role
        self.text = text
        self.streaming = streaming
    }
}

@Observable
final class ChatTab: Identifiable {
    let id = UUID()
    var title: String
    var threadId: String?
    var messages: [ChatMessage] = []
    var transcriptCursor = 0
    var busy = false
    var contextKey: String?
    var task: Task<Void, Never>?

    init(title: String) { self.title = title }
}

@Observable
final class Settings {
    private let d: UserDefaults

    var country: String { didSet { d.set(country, forKey: "country") } }
    var committee: String { didSet { d.set(committee, forKey: "committee") } }
    var delegateName: String { didSet { d.set(delegateName, forKey: "delegateName") } }
    var topic: String { didSet { d.set(topic, forKey: "topic") } }
    var model: String { didSet { d.set(model, forKey: "model") } }
    var deepChat: Bool { didSet { d.set(deepChat, forKey: "deepChat") } }
    var fastDrafts: Bool { didSet { d.set(fastDrafts, forKey: "fastDrafts") } }
    var localeID: String { didSet { d.set(localeID, forKey: "localeID") } }
    var inputDeviceID: Int { didSet { d.set(inputDeviceID, forKey: "inputDeviceID") } }
    var autoDraft: Bool { didSet { d.set(autoDraft, forKey: "autoDraft") } }
    var hideFromCapture: Bool { didSet { d.set(hideFromCapture, forKey: "hideFromCapture") } }
    var panelWidth: Double { didSet { d.set(panelWidth, forKey: "panelWidth") } }
    var dockLeft: Bool { didSet { d.set(dockLeft, forKey: "dockLeft") } }

    var isConfigured: Bool {
        [country, committee, topic].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: [
            "country": "",
            "committee": "",
            "delegateName": "",
            "topic": "",
            "model": "gpt-6.1-sol",
            "deepChat": false,
            "fastDrafts": false,
            "localeID": "en_US",
            "inputDeviceID": 0,
            "autoDraft": true,
            "hideFromCapture": true,
            "panelWidth": 440.0,
            "dockLeft": false,
        ])
        country = d.string(forKey: "country")!
        committee = d.string(forKey: "committee")!
        delegateName = d.string(forKey: "delegateName")!
        topic = d.string(forKey: "topic")!
        model = d.string(forKey: "model")!
        deepChat = d.bool(forKey: "deepChat")
        fastDrafts = d.bool(forKey: "fastDrafts")
        localeID = d.string(forKey: "localeID")!
        inputDeviceID = d.integer(forKey: "inputDeviceID")
        autoDraft = d.bool(forKey: "autoDraft")
        hideFromCapture = d.bool(forKey: "hideFromCapture")
        panelWidth = d.double(forKey: "panelWidth")
        dockLeft = d.bool(forKey: "dockLeft")
    }

    /// Which model + reasoning effort each job uses.
    enum Job { case draft, factCheck, notes, chat }

    func route(_ job: Job) -> (model: String, effort: String) {
        switch job {
        case .draft: return fastDrafts ? ("gpt-6-luna", "low") : (model, "medium")
        case .factCheck: return (model, "high")
        case .notes: return (model, "medium")
        case .chat: return (model, deepChat ? "xhigh" : "medium")
        }
    }

    /// Prefer an exact alias before searching an official country name.
    var shortCountry: String {
        let name = country.trimmingCharacters(in: .whitespacesAndNewlines)
        return Countries.canonicalLabel(name) ?? Countries.canonical(in: name) ?? name
    }
}
