import SwiftUI
import AppKit

/// Lina's visual language: paper, ink, and a serif voice.
/// Interface chrome stays SF Pro (it's a Mac app); anything that *is writing* is set in New York.
enum Theme {
    // MARK: Color

    /// The single brand accent — a deep, slightly warm ink.
    static let ink = Color(nsColor: NSColor(name: "LinaInk") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.66, green: 0.62, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.29, green: 0.24, blue: 0.78, alpha: 1)
    })

    /// Warm paper for writing surfaces.
    static let paper = Color(nsColor: NSColor(name: "LinaPaper") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.105, green: 0.102, blue: 0.098, alpha: 1)
            : NSColor(srgbRed: 0.992, green: 0.985, blue: 0.972, alpha: 1)
    })

    static let paperEdge = Color(nsColor: NSColor(name: "LinaPaperEdge") { appearance in
        appearance.isDark
            ? NSColor(white: 1, alpha: 0.08)
            : NSColor(srgbRed: 0.45, green: 0.38, blue: 0.25, alpha: 0.12)
    })

    static let nsInk = NSColor(name: "LinaInkNS") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.66, green: 0.62, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.29, green: 0.24, blue: 0.78, alpha: 1)
    }

    static let nsPaper = NSColor(name: "LinaPaperNS") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.105, green: 0.102, blue: 0.098, alpha: 1)
            : NSColor(srgbRed: 0.992, green: 0.985, blue: 0.972, alpha: 1)
    }

    /// The color of a thought that hasn't been written yet.
    static let nsGhost = NSColor(name: "LinaGhostNS") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.66, green: 0.62, blue: 1.00, alpha: 0.55)
            : NSColor(srgbRed: 0.29, green: 0.24, blue: 0.78, alpha: 0.45)
    }

    // MARK: Type

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func nsSerif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) {
            return f
        }
        return base
    }

    // MARK: Motion

    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.18)
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - Components

/// A small keyboard keycap, like the ones in Apple's menus and HIG illustrations.
struct KeyCap: View {
    let label: String
    var size: CGFloat = 11

    init(_ label: String, size: CGFloat = 11) {
        self.label = label
        self.size = size
    }

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, size * 0.45)
            .frame(minWidth: size * 1.7, minHeight: size * 1.6)
            .background(
                RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                    .fill(.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

/// The Lina wordmark: lowercase serif with an ink caret, as if mid-sentence.
struct Wordmark: View {
    var size: CGFloat = 22
    @State private var blink = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.04) {
            Text("lina")
                .font(Theme.serif(size, weight: .semibold))
                .tracking(-0.3)
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.ink)
                .frame(width: max(1.5, size * 0.08), height: size * 0.9)
                .offset(y: size * 0.12)
                .opacity(blink ? 0.15 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: blink)
                .onAppear { blink = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lina")
    }
}

/// A rounded group container in the style of macOS System Settings.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

/// Primary pill button, ink-filled.
struct InkButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.white : Theme.ink)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? Theme.ink : Theme.ink.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// NSVisualEffectView bridge for true macOS materials in floating panels.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}
