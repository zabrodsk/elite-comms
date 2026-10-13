import Foundation

extension Moment {
    /// The "Full answer" (or older "Say this") section of a draft, i.e. the words the delegate reads aloud.
    var fullAnswer: String? {
        for marker in ["**Full answer**", "**Say this**"] {
            guard let r = output.range(of: marker) else { continue }
            let body = output[r.upperBound...].drop { $0 != "\n" }
            let end = body.range(of: "\n**")?.lowerBound ?? body.endIndex
            let text = String(body[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Everything we told the delegate to say: points + full answer.
    var spokenWords: String {
        let points = output.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .joined(separator: " ")
        return (fullAnswer ?? "") + " " + points
    }
}

/// Recognises lines spoken by our own delegation, so the app never drafts a reply to the delegate's own words.
enum SelfSpeech {
    /// "The delegation of Australia believes…", "Australia supports…", "Honourable chair, Australia…"
    static func soundsLikeUs(_ text: String, country: String) -> Bool {
        let c = NSRegularExpression.escapedPattern(for: country.lowercased())
        let verbs = "believes|supports|proposes|would like|wishes|thanks|urges|calls|agrees|disagrees|rejects|condemns|recognises|recognizes|welcomes|encourages|reaffirms|is|has|wants|will|stands|strongly|firmly|fully|also|therefore"
        let patterns = [
            #"^\W*(?:thank you,?\s*)?(?:honou?rable\s+)?(?:chair|chairs|president)?,?\s*(?:fellow delegates,?\s*)?(?:the\s+)?(?:delegation|delegate|government|commonwealth|republic)\s+of\s+(?:the\s+)?\#(c)\s+(?:\#(verbs))\b"#,
            #"^\W*(?:thank you,?\s*)?(?:honou?rable\s+)?(?:chair,?\s*)?\#(c)\s+(?:\#(verbs))\b"#,
            #"\b(?:we,?\s+the\s+delegation\s+of\s+\#(c)|on behalf of (?:the\s+)?(?:delegation of\s+)?\#(c)|\#(c)\s+yields)\b"#,
        ]
        let range = NSRange(location: 0, length: (text as NSString).length)
        return patterns.contains { p in
            (try? NSRegularExpression(pattern: p, options: [.caseInsensitive]))?.firstMatch(in: text, range: range) != nil
        }
    }

    /// True when the line is (mostly) the delegate reading out one of our recent drafts.
    @MainActor static func isReadingDraft(_ text: String, moments: [Moment]) -> Bool {
        let words = AppModel.normalize(text)
        guard words.count >= 4 else { return false }
        let recent = moments.prefix(8).filter { !$0.output.isEmpty && Date().timeIntervalSince($0.createdAt) < 600 }
        return recent.contains { m in
            let draft = AppModel.normalize(m.spokenWords)
            guard !draft.isEmpty else { return false }
            return Double(words.intersection(draft).count) / Double(words.count) >= 0.55
        }
    }
}
