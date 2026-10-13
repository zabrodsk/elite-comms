import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Committee notes").font(Theme.title)
                        Group {
                            if let t = model.notesUpdatedAt {
                                Text("Updated \(t, style: .relative) ago")
                            } else {
                                Text("Tap Refresh to summarise positions, blocs and proposals")
                            }
                        }
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Button {
                        model.refreshNotes()
                    } label: {
                        if model.notesBusy { ProgressView().controlSize(.mini) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(model.notesBusy || model.segments.isEmpty)
                }
                if model.notes.isEmpty {
                    Text(model.segments.isEmpty ? "Start listening and notes will build up here." : "Tap Refresh to build notes from the debate so far.")
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 30).frame(maxWidth: .infinity)
                } else {
                    MarkdownText(text: model.notes, size: 13)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 6) {
                    Button { copy(model.exportTranscript) } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    Spacer()
                    Button("New session") { model.newSession() }.buttonStyle(PillButtonStyle(kind: .ghost))
                }
            }
            .padding(16)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct BriefView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTarget = false
    @State private var devices: [MicCapture.Device] = []
    @State private var models: [String] = []

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var m = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Delegation") {
                    field("Country", text: $settings.country)
                    field("Committee", text: $settings.committee)
                    field("Delegate", text: $settings.delegateName)
                    field("Current topic", text: $settings.topic)
                    if !settings.isConfigured {
                        Text("Enter your country, committee and topic, then add your position paper or study guide below.")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }

                section("Background the AI knows") {
                    VStack(spacing: 0) {
                        ForEach(model.briefDocs) { d in
                            HStack {
                                Image(systemName: d.url.pathExtension == "pdf" ? "doc.richtext" : "doc.text")
                                    .foregroundStyle(Theme.textTertiary)
                                Text(d.name).font(Theme.body).lineLimit(1)
                                Spacer()
                                Text("\(d.words.formatted()) words").font(Theme.mono).foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(d.url) }
                            if d.id != model.briefDocs.last?.id { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(dropTarget ? Theme.accent : Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: dropTarget ? [4] : [])))
                    .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                        for p in providers {
                            _ = p.loadObject(ofClass: URL.self) { url, _ in
                                if let url { Task { @MainActor in model.importBrief([url]) } }
                            }
                        }
                        return true
                    }
                    HStack(spacing: 6) {
                        Button { pickFiles() } label: { Label("Add files", systemImage: "plus") }.buttonStyle(PillButtonStyle(kind: .secondary))
                        Button { NSWorkspace.shared.open(BriefStore.briefURL) } label: { Label("Open folder", systemImage: "folder") }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                        Button { model.reloadBrief() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                            .buttonStyle(PillButtonStyle(kind: .ghost))
                    }
                }

                section("My notes") {
                    TextEditor(text: $m.myNotes)
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(8)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
                        .onChange(of: model.myNotes) { model.saveMyNotes() }
                }

                section("AI (via your Codex account)") {
                    row("Model") {
                        Picker("", selection: $settings.model) {
                            ForEach(Array(Set(models + [settings.model])).sorted(), id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 170)
                    }
                    Toggle("Deep thinking in chat (xhigh)", isOn: $settings.deepChat)
                    Toggle("Faster live drafts (GPT-6-Luna)", isOn: $settings.fastDrafts)
                    Toggle("Auto-draft when \(settings.shortCountry) is addressed", isOn: $settings.autoDraft)
                    if let e = model.codexError {
                        Text(e).font(Theme.caption).foregroundStyle(Theme.warn)
                    }
                }

                section("Transcription") {
                    row("Microphone") {
                        Picker("", selection: $settings.inputDeviceID) {
                            Text("System default").tag(0)
                            ForEach(devices) { Text($0.name).tag(Int($0.id)) }
                        }.labelsHidden().frame(width: 190)
                    }
                    row("Accent model") {
                        Picker("", selection: $settings.localeID) {
                            Text("English (US)").tag("en_US")
                            Text("English (UK)").tag("en_GB")
                            Text("English (Australia)").tag("en_AU")
                            Text("English (India)").tag("en_IN")
                            Text("English (Canada)").tag("en_CA")
                        }.labelsHidden().frame(width: 190)
                    }
                }

                section("Window") {
                    Toggle("Hide from screen sharing & screenshots", isOn: $settings.hideFromCapture)
                    Toggle("Dock on the left", isOn: $settings.dockLeft)
                    Text("⌘\\ hide · ⇧⌘\\ listen · ⌥⌘↩ help me answer · ⌥⌘1–4 actions")
                        .font(Theme.mono).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(16)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .task {
            devices = MicCapture.inputDevices()
            models = await model.codex.listModels()
        }
    }

    private func effortPicker(_ b: Binding<String>) -> some View {
        Picker("", selection: b) {
            ForEach(["minimal", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
        }.labelsHidden().frame(width: 120)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.label).foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.label).foregroundStyle(Theme.textSecondary)
            TextField("", text: text).textFieldStyle(.plain).font(Theme.body)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.hairline))
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack { Text(label).font(Theme.body); Spacer(); content() }
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        if p.runModal() == .OK { model.importBrief(p.urls) }
    }
}
