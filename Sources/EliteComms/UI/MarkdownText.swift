import SwiftUI

/// Lightweight block Markdown renderer for streamed model output (headings, bullets, quotes, inline styles).
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        let bs = blocks
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(bs.enumerated()), id: \.offset) { i, b in
                switch (b, Self.section(before: i, in: bs)) {
                case (.bullet(let t, _), "points"):
                    // The glanceable part: what to say, in a few words.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(y: -3)
                        Text(inline(t)).font(Theme.ui(size + 2.5, .semibold)).foregroundStyle(Theme.textPrimary)
                    }
                case (.para(let t), "full answer"):
                    Text(inline(t)).font(Theme.ui(size + 1)).foregroundStyle(Theme.textPrimary).lineSpacing(3)
                default:
                    block(b)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Lowercased title of the heading this block sits under ("points", "full answer", …).
    private static func section(before index: Int, in bs: [Block]) -> String {
        for j in stride(from: index - 1, through: 0, by: -1) {
            if case .heading(let h) = bs[j] {
                return h.lowercased().replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            }
        }
        return ""
    }

    private enum Block { case heading(String), bullet(String, Int), quote(String), para(String), numbered(String, String) }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.para(para.joined(separator: " "))); para.removeAll() } }
        for raw in text.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("**"), let close = line.dropFirst(2).range(of: "**") {
                // "**Say this** (~30 sec) text…" → heading + body, so the speakable part stands alone.
                flush()
                let title = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
                var rest = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
                var note = ""
                if rest.hasPrefix("("), let end = rest.firstIndex(of: ")") {
                    note = " " + String(rest[...end]); rest = String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                }
                if title.hasSuffix(":") || title.count > 40 {
                    para.append(line)   // inline bold like "**Verdict:** FALSE" stays a sentence
                } else {
                    out.append(.heading(title + note))
                    if !rest.isEmpty { para.append(rest) }
                }
            } else if line.hasPrefix("#") {
                flush(); out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); out.append(.bullet(String(line.dropFirst(2)), indent / 2))
            } else if line.hasPrefix(">") {
                flush(); out.append(.quote(line.drop { $0 == ">" }.trimmingCharacters(in: .whitespaces)))
            } else if let r = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
                flush(); out.append(.numbered(String(line[r].trimmingCharacters(in: .whitespaces)), String(line[r.upperBound...])))
            } else {
                para.append(line)
            }
        }
        flush()
        return out
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .heading(let s):
            Text(inline(s)).font(.system(size: size - 1, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase).tracking(0.4).padding(.top, 4)
        case .bullet(let s, let level):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(Theme.textTertiary).frame(width: 4, height: 4).offset(y: -2)
                Text(inline(s)).font(.system(size: size))
            }
            .padding(.leading, CGFloat(level) * 12)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).font(.system(size: size, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                Text(inline(s)).font(.system(size: size))
            }
        case .quote(let s):
            Text(inline(s)).font(.system(size: size)).foregroundStyle(Theme.textSecondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 2) }
        case .para(let s):
            Text(inline(s)).font(.system(size: size)).lineSpacing(2)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
