import AppKit
import Foundation
import Observation
import SwiftUI

/// User-triggered help. Nothing here runs on a timer: the model is only called when the delegate presses a
/// button, hits Enter / a hotkey, or an on-device keyword trigger fires (handled in `AppModel.ingest`).
enum QuickAction: CaseIterable, Identifiable {
    case answer, factCheck, hitBack, speech

    var id: Self { self }

    var title: String {
        switch self {
        case .answer: return "Help me answer"
        case .factCheck: return "Fact-check"
        case .hitBack: return "Hit back"
        case .speech: return "Speech"
        }
    }

    var symbol: String {
        switch self {
        case .answer: return "bubble.left.and.text.bubble.right"
        case .factCheck: return "checkmark.seal"
        case .hitBack: return "bolt"
        case .speech: return "mic"
        }
    }

    /// Global shortcut digit: ⌥⌘1…4.
    var digit: Int {
        switch self {
        case .answer: return 1
        case .factCheck: return 2
        case .hitBack: return 3
        case .speech: return 4
        }
    }

    var kind: Moment.Kind {
        switch self {
        case .answer: return .help
        case .factCheck: return .factCheck
        case .hitBack: return .hitBack
        case .speech: return .speech
        }
    }
}

/// Which transcript line the delegate clicked (actions target it instead of "the last speaker").
@Observable
final class Selection {
    static let shared = Selection()
    var segmentID: UUID?
}

extension AppModel {
    /// The text an action should work on: the clicked line's whole turn, or the most recent turn by someone other
    /// than the chair (falling back to the last ~60 s of talk).
    func actionTarget() -> (quote: String, speaker: String?)? {
        guard !segments.isEmpty else { return nil }
        var end: Int
        if let id = Selection.shared.segmentID, let i = segments.firstIndex(where: { $0.id == id }) {
            end = i
        } else if let i = segments.lastIndex(where: { $0.speaker != "Chair" && $0.speaker != nil }) {
            end = i
        } else {
            let cutoff = Date().addingTimeInterval(-60)
            let recent = segments.filter { $0.date >= cutoff }
            let lines = recent.isEmpty ? Array(segments.suffix(3)) : recent
            return (lines.map(\.text).joined(separator: " "), lines.last?.speaker)
        }
        // Walk back over the same speaker's consecutive lines to get their whole turn.
        let speaker = segments[end].speaker
        var start = end
        while start > 0, segments[start - 1].speaker == speaker,
              segments[start].date.timeIntervalSince(segments[start - 1].date) < 45 {
            start -= 1
        }
        let text = segments[start...end].map(\.text).joined(separator: " ")
        return (String(text.suffix(900)), speaker)
    }

    func perform(_ action: QuickAction) {
        guard requireDelegation() else { return }
        let target = actionTarget()
        if target == nil && action != .speech { NSSound.beep(); return }
        let m = Moment(kind: action.kind,
                       quote: target?.quote ?? "(no transcript yet)",
                       speaker: target?.speaker,
                       why: nil, urgency: "high")
        withAnimation(Theme.spring) {
            moments.insert(m, at: 0)
            tab = .live
        }
        Selection.shared.segmentID = nil
        run(m, action: action == .factCheck ? .factCheck : .draft)
    }
}
