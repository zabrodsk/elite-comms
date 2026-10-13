import AppKit
import SwiftUI

struct PanelRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Header()
            TabBar()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            BottomBar()
        }
        .foregroundStyle(Theme.textPrimary)
        .background {
            ZStack {
                PaperBackground()
                Theme.paper.opacity(0.92)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .live: LiveView()
        case .notes: NotesView()
        case .brief: BriefView()
        case .chat(let id):
            if let t = model.chat(id) { ChatView(tab: t).id(t.id) } else { LiveView() }
        }
    }
}

// MARK: - Header (one row)

private struct Header: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("elite-comms").font(Theme.serif(22))
                Text(model.settings.isConfigured ? "\(model.settings.shortCountry) · \(model.settings.committee)" : "Set up your delegation")
                    .font(Theme.ui(11.5, .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            RecordPill()
            IconButton(symbol: "sidebar.trailing", help: "Hide (⌘\\)", size: 13) {
                (NSApp.delegate as? AppDelegate)?.togglePanel()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }


}

/// Wispr-style record capsule: green dot + label; timer and live level bars while recording.
private struct RecordPill: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { model.toggleListening() } label: {
            HStack(spacing: 7) {
                if model.isListening {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.record).frame(width: 9, height: 9)
                    LevelBars(level: model.level)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsed).font(Theme.ui(12.5, .semibold).monospacedDigit())
                    }
                } else if model.isActive {
                    ProgressView().controlSize(.mini)
                    Text("Starting").font(Theme.ui(12.5, .semibold))
                } else {
                    Circle().fill(Theme.record).frame(width: 9, height: 9)
                    Text(model.sessionStart == nil ? "Listen" : "Resume").font(Theme.ui(12.5, .semibold))
                }
            }
            .foregroundStyle(Theme.record)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.recordFill, in: Capsule())
            .overlay(Capsule().stroke(Theme.record.opacity(hover ? 0.45 : 0.22), lineWidth: 1))
            .animation(Theme.snap, value: model.isListening)
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help("Start/stop listening (⇧⌘\\)")
    }

    private var elapsed: String {
        guard let s = model.sessionStart else { return "0:00" }
        let t = Int(Date().timeIntervalSince(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

private struct LevelBars: View {
    let level: Float
    private let weights: [CGFloat] = [0.55, 1, 0.75]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(Theme.record)
                    .frame(width: 2.5, height: 4 + 10 * CGFloat(level) * weights[i])
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

// MARK: - Tabs (springy underline like Wispr)

private struct TabBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    tabButton(.live, "Live", badge: model.pendingMoments.filter { $0.state == .pending }.count)
                    tabButton(.notes, "Notes")
                    ForEach(model.chats) { c in
                        tabButton(.chat(c.id), c.title, closable: model.chats.count > 1 ? c : nil, busy: c.busy)
                    }
                    IconButton(symbol: "plus", help: "New chat") {
                        withAnimation(Theme.spring) { _ = model.newChat() }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
            IconButton(symbol: "gearshape", help: "Brief & settings", size: 12.5) {
                withAnimation(Theme.spring) { model.tab = model.tab == .brief ? .live : .brief }
            }
            .padding(.trailing, 12)
        }
        .frame(height: 36)
    }

    private func tabButton(_ t: AppModel.Tab, _ title: String, badge: Int = 0, closable: ChatTab? = nil, busy: Bool = false) -> some View {
        let active = model.tab == t
        return Button {
            withAnimation(Theme.spring) { model.tab = t }
        } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1).frame(maxWidth: 110)
                if busy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10) }
                if badge > 0 {
                    Text("\(badge)").font(Theme.ui(10.5, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                        .background(Theme.accent, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
                if let c = closable, active {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.textTertiary)
                        .onTapGesture { withAnimation(Theme.spring) { model.closeChat(c) } }
                }
            }
            .font(Theme.tab)
            .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .overlay(alignment: .bottom) {
                if active {
                    Capsule().fill(Theme.textPrimary).frame(height: 2)
                        .matchedGeometryEffect(id: "underline", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bottom: quick actions + ask box

private struct BottomBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if !isChat {
                HStack(spacing: 6) {
                    ForEach(QuickAction.allCases) { a in
                        ActionButton(action: a) { model.perform(a) }
                    }
                }
                .padding(.horizontal, 12)
                if let target = Selection.shared.segmentID.flatMap({ id in model.segments.first { $0.id == id } }) {
                    HStack(spacing: 6) {
                        Text("Using: \(target.speaker ?? "selected line")").font(Theme.caption).foregroundStyle(Theme.accent)
                        Spacer()
                        Button("Clear") { Selection.shared.segmentID = nil }
                            .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(14))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(submit)
                    .padding(.vertical, 6)
                if let t = activeChat, t.busy {
                    Button { model.stopChat(t) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                            .frame(width: 30, height: 30).background(Theme.ink, in: Circle()).foregroundStyle(Theme.inkText)
                    }.buttonStyle(PressableStyle())
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(Theme.ink, in: Circle())
                            .foregroundStyle(Theme.inkText)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 6)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(focused ? Theme.textTertiary.opacity(0.6) : Theme.hairline, lineWidth: 1))
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .onReceive(NotificationCenter.default.publisher(for: .focusAsk)) { _ in focused = true }
    }

    private var isChat: Bool { activeChat != nil }

    private var activeChat: ChatTab? {
        if case .chat(let id) = model.tab { return model.chat(id) }
        return nil
    }

    private var placeholder: String {
        isChat ? "Ask anything…" : "Ask, or press ↩ for help answering"
    }

    /// Enter with an empty box = "Help me answer" (the fastest trigger). Otherwise send to chat.
    private func submit() {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty {
            if !isChat { model.perform(.answer) }
            return
        }
        let target = activeChat ?? model.chats.first(where: { !$0.busy }) ?? model.newChat()
        withAnimation(Theme.spring) { model.tab = .chat(target.id) }
        model.send(msg, in: target)
        text = ""
    }
}

private struct ActionButton: View {
    let action: QuickAction
    let run: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: action.symbol).font(.system(size: 13, weight: .medium))
                Text(action.title).font(Theme.ui(11, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(action == .answer ? Theme.inkText : Theme.textSecondary)
            .background(action == .answer ? (hover ? Theme.ink.opacity(0.86) : Theme.ink) : (hover ? Theme.chipHover : Theme.chip),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(action == .answer ? .clear : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("\(action.title) (⌥⌘\(action.digit))")
    }
}
