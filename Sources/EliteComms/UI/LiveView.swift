import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var pinned = true
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.pendingMoments.isEmpty {
                moments
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            if model.segments.isEmpty && model.volatileText.isEmpty {
                emptyState
            } else {
                transcript
            }
        }
    }

    // MARK: Cards

    private var moments: some View {
        let all = model.pendingMoments
        let visible = showAll ? all : Array(all.prefix(2))
        return VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(visible) { m in
                        MomentCard(moment: m)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.97))))
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: showAll ? 560 : 400)
            .fixedSize(horizontal: false, vertical: true)
            if all.count > 2 {
                Button(showAll ? "Show less" : "\(all.count - 2) more") {
                    withAnimation(Theme.spring) { showAll.toggle() }
                }
                .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(Theme.spring, value: model.pendingMoments.map(\.id))
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.segments.enumerated()), id: \.element.id) { i, seg in
                            SegmentRow(segment: seg,
                                       showHeader: i == 0 || model.segments[i - 1].speaker != seg.speaker
                                           || seg.date.timeIntervalSince(model.segments[i - 1].date) > 120)
                        }
                        if !model.volatileText.isEmpty {
                            VolatileRow(text: model.volatileText)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { pinned = true }
                            .onDisappear { pinned = false }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 30)
                    }
                }
                .onChange(of: model.segments.count) { if pinned { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } } }
                .onChange(of: model.volatileText) { if pinned { proxy.scrollTo("bottom", anchor: .bottom) } }

                if !pinned {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Theme.surfaceRaised, in: Circle())
                            .overlay(Circle().stroke(Theme.hairline))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Theme.spring, value: pinned)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            switch model.status {
            case .preparing(let s):
                ProgressView().controlSize(.small)
                Text(s).font(Theme.body).foregroundStyle(Theme.textSecondary)
            case .downloading(let p):
                ProgressView(value: p).frame(width: 160)
                Text("Getting the speech model… \(Int(p * 100))%").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            case .listening:
                ListeningOrb(level: model.level)
                Text("Listening…").font(Theme.body).foregroundStyle(Theme.textSecondary)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(Theme.warn)
                Text(msg).font(Theme.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                Button("Try again") { model.start() }.buttonStyle(PillButtonStyle(kind: .primary))
            case .idle:
                Button { model.start() } label: {
                    ZStack {
                        Circle().fill(Theme.ink).frame(width: 60, height: 60)
                        Image(systemName: "mic.fill").font(.system(size: 21, weight: .medium)).foregroundStyle(Theme.inkText)
                    }
                }
                .buttonStyle(PressableStyle())
                Text("Start listening").font(Theme.title)
                Text("⇧⌘\\").font(Theme.mono).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// One transcript line. Click to make it the target of the quick actions.
struct SegmentRow: View {
    @Environment(AppModel.self) private var model
    let segment: Segment
    let showHeader: Bool
    @State private var hover = false

    private var selected: Bool { Selection.shared.segmentID == segment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showHeader {
                SpeakerLabel(segment: segment).padding(.top, 10)
            }
            HStack(spacing: 0) {
                Text(segment.text)
                    .font(Theme.transcript)
                    .foregroundStyle((segment.confidence ?? 1) < 0.4 ? Theme.textSecondary : Theme.textPrimary)
                    .lineSpacing(4)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(stroke, lineWidth: selected ? 1.5 : 1)
                    }
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.12)) {
                            Selection.shared.segmentID = selected ? nil : segment.id
                        }
                    }
                Spacer(minLength: 24)
            }
        }
        .onHover { hover = $0 }
    }

    private var fill: Color {
        if segment.hit != .none { return Theme.accentFill }
        return hover || selected ? Theme.chipHover : Theme.surface
    }

    private var stroke: Color {
        if selected { return Theme.accent }
        switch segment.hit {
        case .directed: return Theme.accent.opacity(0.6)
        case .mention: return Theme.accent.opacity(0.3)
        case .none: return .clear
        }
    }
}

/// "Chair" / "Delegate of X" label. Click to correct it; the fix applies to that voice everywhere.
struct SpeakerLabel: View {
    @Environment(AppModel.self) private var model
    let segment: Segment

    var body: some View {
        Menu {
            ForEach(model.knownSpeakers, id: \.self) { name in
                Button(name) { model.relabel(segmentID: segment.id, as: name) }
            }
            Divider()
            Menu("Other country") {
                ForEach(Countries.names, id: \.self) { name in
                    Button(name) { model.relabel(segmentID: segment.id, as: name) }
                }
            }
        } label: {
            Text(display)
                .font(Theme.ui(12.5, .semibold))
                .foregroundStyle(segment.speaker == "Chair" ? Theme.textPrimary : Theme.textSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Wrong speaker? Click to fix")
    }

    private var display: String {
        guard let s = segment.speaker else { return "Unknown speaker" }
        if s == "Chair" || s.hasPrefix("Delegate of ") { return s }
        return "Delegate of \(s)"
    }
}

/// Interim words: grey, settle into a normal bubble once final (Wispr behaviour).
struct VolatileRow: View {
    let text: String
    var body: some View {
        HStack {
            Text(text)
                .font(Theme.transcript)
                .foregroundStyle(Theme.textTertiary)
                .lineSpacing(4)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 24)
        }
    }
}

struct ListeningOrb: View {
    let level: Float
    var body: some View {
        ZStack {
            Circle().fill(Theme.record.opacity(0.10)).frame(width: 60 + CGFloat(level) * 30)
            Circle().fill(Theme.record.opacity(0.18)).frame(width: 48 + CGFloat(level) * 14)
            Image(systemName: "waveform").font(.system(size: 19, weight: .medium)).foregroundStyle(Theme.record)
        }
        .frame(width: 96, height: 96)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
