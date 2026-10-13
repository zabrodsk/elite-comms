import AppKit
import SwiftUI

struct MomentCard: View {
    @Environment(AppModel.self) private var model
    @Bindable var moment: Moment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showQuote {
                Text(moment.quote)
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(moment.state == .pending ? 3 : 2)
            }
            content
        }
        .padding(12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(isHot ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1)
        )
    }

    private var isHot: Bool { moment.kind == .floor || moment.kind == .directed }
    /// Quick-action cards were asked for by the delegate, so the quote is just noise there.
    private var showQuote: Bool { ![.help, .hitBack, .speech].contains(moment.kind) || moment.state == .pending }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(kindColor).frame(width: 7, height: 7)
                .overlay { if isHot && moment.state == .pending { PulseRing(color: kindColor) } }
            Text(moment.kind.label).font(Theme.ui(12.5, .semibold))
            if let s = speakerText {
                Text(s).font(Theme.ui(12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if moment.state == .done {
                IconButton(symbol: "doc.on.doc", help: "Copy the full answer") { copySayThis() }
                IconButton(symbol: "arrow.clockwise", help: "Try again") { model.run(moment, action: moment.action ?? .draft) }
            }
            IconButton(symbol: "xmark", help: "Dismiss") { withAnimation(Theme.spring) { model.dismiss(moment) } }
        }
    }

    private var speakerText: String? {
        guard let s = moment.speaker, !s.isEmpty, s.lowercased() != "unknown" else { return nil }
        return "· " + s.replacingOccurrences(of: "Delegate of ", with: "")
    }

    private var kindColor: Color {
        switch moment.kind {
        case .floor, .directed, .help, .speech: return Theme.accent
        case .factCheck: return Theme.warn
        case .hitBack: return Theme.danger
        case .mention: return Theme.info
        case .opportunity: return Theme.good
        }
    }

    @ViewBuilder private var content: some View {
        switch moment.state {
        case .pending:
            HStack(spacing: 6) {
                if moment.kind == .factCheck {
                    Button("Fact-check") { model.run(moment, action: .factCheck) }.buttonStyle(PillButtonStyle(kind: .primary))
                } else {
                    Button(moment.kind == .floor ? "Write my speech" : "Help me answer") { model.run(moment, action: .draft) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                    Button("Fact-check") { model.run(moment, action: .factCheck) }.buttonStyle(PillButtonStyle(kind: .ghost))
                }
            }
        case .working, .done, .failed:
            VStack(alignment: .leading, spacing: 8) {
                if !moment.status.isEmpty || (moment.state == .working && moment.output.isEmpty) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(moment.status.isEmpty ? "Thinking…" : moment.status)
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            .shimmering()
                    }
                }
                if !moment.output.isEmpty {
                    MarkdownText(text: moment.output, size: 13.5)
                }
                if case .failed(let e) = moment.state {
                    Text(e).font(Theme.caption).foregroundStyle(Theme.warn)
                }
            }
        case .dismissed:
            EmptyView()
        }
    }

    private func copySayThis() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(moment.fullAnswer ?? moment.output, forType: .string)
    }
}

struct PulseRing: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle().stroke(color, lineWidth: 1.5)
            .scaleEffect(on ? 2.6 : 1).opacity(on ? 0 : 0.8)
            .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { on = true } }
    }
}
