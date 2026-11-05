import AppKit
import SwiftUI

enum IPasteStyle {
    static let accent = Color(red: 0.20, green: 0.48, blue: 0.94)
    static let cardRadius: CGFloat = 20
}

/// Keep glass on navigation and controls, with readable material beneath content.
struct IPasteGlassContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) { content }
        } else {
            content
        }
    }
}

private struct IPasteGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.stroke(tint?.opacity(0.6) ?? Color.primary.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .background(tint?.opacity(0.12) ?? .clear, in: shape)
                .overlay(shape.stroke(.white.opacity(0.3), lineWidth: 1).allowsHitTesting(false))
        }
    }
}

extension View {
    func ipasteGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(IPasteGlassSurface(shape: shape, tint: tint, interactive: interactive))
    }
}

/// Keep standard Button activation, keyboard shortcuts, and drag cancellation.
/// The glass material alone provides very little mouse feedback on macOS.
struct IPasteButtonStyle<S: InsettableShape>: ButtonStyle {
    let shape: S
    var tint: Color? = nil
    var glass = true
    var horizontalPadding: CGFloat = 0
    var verticalPadding: CGFloat = 0

    init(in shape: S, tint: Color? = nil, glass: Bool = true,
         horizontalPadding: CGFloat = 0, verticalPadding: CGFloat = 0) {
        self.shape = shape
        self.tint = tint
        self.glass = glass
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    func makeBody(configuration: Configuration) -> some View {
        IPasteButtonBody(label: configuration.label, isPressed: configuration.isPressed,
            shape: shape, tint: tint, glass: glass,
            horizontalPadding: horizontalPadding, verticalPadding: verticalPadding)
    }
}

private struct IPasteButtonBody<Label: View, S: InsettableShape>: View {
    let label: Label
    let isPressed: Bool
    let shape: S
    let tint: Color?
    let glass: Bool
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    @ViewState<Bool> private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder private var surface: some View {
        let paddedLabel = label.padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
        if glass { paddedLabel.ipasteGlass(in: shape, tint: tint) }
        else { paddedLabel }
    }

    var body: some View {
        let pressed = isEnabled && isPressed
        let hovered = isEnabled && hovering
        // Glass tints may be translucent (for selected tabs); feedback keeps
        // full-strength color so selected and unselected buttons respond alike.
        let accent = glass ? IPasteStyle.accent : (tint ?? IPasteStyle.accent)
        surface
            .overlay {
                ZStack {
                    shape.fill(accent.opacity(pressed ? 0.22 : (hovered ? 0.11 : 0)))
                    if hovered && !pressed {
                        shape.fill(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.09 : 0.18), .clear],
                            startPoint: .top, endPoint: .bottom))
                    }
                }.allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(accent.opacity(pressed ? 0.65 : (hovered ? 0.45 : 0)), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: accent.opacity(hovered && !pressed ? 0.17 : 0), radius: 7, y: 3)
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.94 : (hovered ? 1.025 : 1)))
            .offset(y: reduceMotion || !hovered || pressed ? 0 : -1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: pressed ? 0.07 : 0.16), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
    }
}

/// Behind-window blending samples the desktop even in the borderless shelf panel.
struct IPasteBackdrop: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = reduceTransparency ? .inactive : .active
    }
}

struct IPastePanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                IPasteBackdrop()
                Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.28 : 0.18)
                LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.07 : 0.28), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.allowsHitTesting(false)
    }
}
