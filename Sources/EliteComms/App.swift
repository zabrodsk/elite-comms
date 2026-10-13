import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
enum EliteCommsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Side panel that can take keyboard focus (for chat) without activating like a normal window.
final class SidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: SidePanel!
    private var statusItem: NSStatusItem!
    private var hotKeys: [EventHotKeyRef?] = []
    let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        installMainMenu()
        buildPanel()
        installStatusItem()
        installHotKeys()
        observeSettings()
        showPanel()
        model.warmUpCodex()
        if ProcessInfo.processInfo.environment["ELITE_AUTOSTART"] == "1" { model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.codex.shutdown()
    }

    // MARK: Panel

    private func buildPanel() {
        panel = SidePanel(contentRect: .zero,
                          styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 340, height: 400)

        let host = NSHostingView(rootView: PanelRoot().environment(model))
        host.sizingOptions = []
        panel.contentView = host
        applyCapturePolicy()
        layoutPanel()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutPanel() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.settings.panelWidth = Double(self.panel.frame.width)
                self.layoutPanel()
            }
        }
    }

    func layoutPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let inset: CGFloat = 10
        let width = min(max(CGFloat(model.settings.panelWidth), 340), vf.width * 0.5)
        let x = model.settings.dockLeft ? vf.minX + inset : vf.maxX - width - inset
        panel.setFrame(NSRect(x: x, y: vf.minY + inset, width: width, height: vf.height - inset * 2), display: true)
    }

    private func applyCapturePolicy() {
        panel.sharingType = model.settings.hideFromCapture ? .none : .readOnly
    }

    func showPanel() {
        layoutPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func togglePanel() {
        if panel.isVisible && panel.alphaValue > 0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.panel.orderOut(nil) }
            })
        } else {
            showPanel()
        }
    }

    func focusAsk() {
        if !panel.isVisible { showPanel() }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .focusAsk, object: nil)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = model.settings.hideFromCapture
            _ = model.settings.dockLeft
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyCapturePolicy()
                self?.layoutPanel()
                self?.observeSettings()
            }
        }
    }

    // MARK: Status item & menu

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "elite-comms")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide Panel  ⌘\\", action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Start / Stop Listening  ⇧⌘\\", action: #selector(menuListen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Help Me Answer  ⌥⌘↩", action: #selector(menuAsk), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Brief Folder", action: #selector(openBrief), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Sessions Folder", action: #selector(openSessions), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit elite-comms", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func menuToggle() { togglePanel() }
    @objc private func menuListen() { model.toggleListening() }
    @objc private func menuAsk() { model.perform(.answer) }
    @objc private func openBrief() { NSWorkspace.shared.open(BriefStore.briefURL) }
    @objc private func openSessions() { NSWorkspace.shared.open(BriefStore.sessionsURL) }

    /// Accessory apps still route ⌘C/⌘V/⌘A through the main menu, so text fields need an Edit menu.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit elite-comms", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: Global hotkeys (Carbon: no Accessibility permission needed)

    private func installHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let d = NSApp.delegate as? AppDelegate else { return }
                    switch hk.id {
                    case 1: d.togglePanel()
                    case 2: d.model.toggleListening()
                    case 3: d.model.perform(.answer)
                    case 11...14:
                        if let a = QuickAction.allCases.first(where: { $0.digit == Int(hk.id) - 10 }) { d.model.perform(a) }
                    default: break
                    }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        func register(_ key: Int, _ mods: Int, _ id: UInt32) {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: OSType(0x454C4954), id: id),
                                GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
        register(kVK_ANSI_Backslash, cmdKey, 1)              // ⌘\  show/hide (Cluely-style)
        register(kVK_ANSI_Backslash, cmdKey | shiftKey, 2)   // ⇧⌘\ start/stop listening (Cluely-style)
        register(kVK_Return, cmdKey | optionKey, 3)          // ⌥⌘↩ help me answer (from any app)
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]
        for (i, key) in digits.enumerated() {                // ⌥⌘1…4 quick actions
            register(key, cmdKey | optionKey, UInt32(11 + i))
        }
    }
}

extension Notification.Name {
    static let focusAsk = Notification.Name("focusAsk")
}
