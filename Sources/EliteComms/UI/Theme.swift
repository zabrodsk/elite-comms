import AppKit
import CoreText
import SwiftUI

/// Tokens lifted from Wispr Flow's Notetaker (warm "paper" palette, Figtree + EB Garamond),
/// with a Cluely-style translucent backing.
enum Theme {
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    private static let hasFigtree = { NSFont(name: "Figtree", size: 12) != nil || NSFontManager.shared.availableFontFamilies.contains("Figtree") }()
    private static let hasGaramond = { NSFontManager.shared.availableFontFamilies.contains("EB Garamond") }()

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasFigtree ? .custom("Figtree", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func serif(_ size: CGFloat) -> Font {
        hasGaramond ? .custom("EB Garamond", size: size) : .system(size: size, weight: .regular, design: .serif)
    }

    // Type scale (Wispr: 15 body, 12 labels, 550 label weight, 600 tabs)
    static var transcript: Font { ui(14.5, .medium) }
    static var body: Font { ui(13.5) }
    static var caption: Font { ui(12) }
    static var label: Font { ui(12, .medium) }
    static var tab: Font { ui(13.5, .semibold) }
    static var title: Font { serif(23) }
    static var display: Font { serif(28) }
    static var mono: Font { .system(size: 10.5, weight: .regular, design: .monospaced) }

    // Colours (light / dark)
    static let paper = dyn(0xFCFCFB, 0x1A1A1A)
    static let surface = dyn(0xF5F4F0, 0x202020)        // background-tertiary (bubbles)
    static let surfaceRaised = dyn(0xFFFFFF, 0x262625)  // cards
    static let secondary = dyn(0xEEEBE3, 0x30302F)      // user bubbles, borders
    static let hairline = dyn(0xEEEBE3, 0x30302F)
    static let chip = dyn(0xF7F6F2, 0x262625)
    static let chipHover = dyn(0xF5F4F0, 0x343432)
    static let textPrimary = dyn(0x1A1A1A, 0xE9E8E1)
    static let textSecondary = dyn(0x4D4A42, 0xC5C0B3)
    static let textTertiary = dyn(0x71716E, 0x9D9C98)
    static let ink = dyn(0x1A1A1A, 0xE9E8E1)
    static let inkText = dyn(0xFCFCFB, 0x1A1A1A)
    static let record = dyn(0x059669, 0x34D399)
    static let recordFill = dyn(0xECFDF5, 0x163A2E)
    static let accent = dyn(0xA26EC1, 0xC89BE3)         // Wispr "dawn lilac": things aimed at you
    static let accentFill = dyn(0xFCF7FF, 0x2A1F31)
    static let warn = dyn(0xC2410C, 0xFB923C)
    static let danger = dyn(0xDC2626, 0xFF5757)
    static let info = dyn(0x736E62, 0xA39D8E)
    static let good = dyn(0x034F46, 0x5EC4B6)           // Wispr "fathom teal"

    static let cardRadius: CGFloat = 12
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let snap = Animation.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.22)

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Backing material (Cluely translucency under Wispr paper)

struct PaperBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Controls

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, record }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(Theme.ui(12, .semibold))
                .labelStyle(TightLabelStyle())
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(fg)
                .background(bg, in: Capsule())
                .overlay(Capsule().stroke(border, lineWidth: 1))
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
        }

        private var fg: Color {
            switch kind {
            case .primary: return Theme.inkText
            case .secondary: return Theme.textSecondary
            case .ghost: return hover ? Theme.textPrimary : Theme.textTertiary
            case .record: return Theme.record
            }
        }
        private var bg: Color {
            switch kind {
            case .primary: return hover ? Theme.ink.opacity(0.86) : Theme.ink
            case .secondary: return hover ? Theme.chipHover : Theme.chip
            case .ghost: return hover ? Theme.chip : .clear
            case .record: return Theme.recordFill
            }
        }
        private var border: Color {
            switch kind {
            case .secondary: return Theme.hairline
            case .record: return Theme.record.opacity(0.25)
            default: return .clear
            }
        }
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 10.5, weight: .semibold))
            configuration.title
        }
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 12
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hover ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 24, height: 24)
                .background(hover ? Theme.chip : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Shimmer (Wispr "generating" label)

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Theme.paper.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.5)
                        .offset(x: phase * g.size.width * 1.5)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}
