import SwiftUI
import AppKit

@MainActor final class ShelfPresentation: ObservableObject {
    @Published var isPresented = false
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var hideDuration: TimeInterval { reduceMotion ? 0.10 : 0.18 }

    static func frame(screen: NSRect, visible: NSRect, size: ShelfDisplaySize = .standard) -> NSRect {
        NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: min(size.panelHeight, max(1, visible.height - 20)))
    }
}

struct ShelfContainerView<Content: View>: View {
    @ObservedObject var presentation: ShelfPresentation
    let content: Content

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(y: presentation.reduceMotion || presentation.isPresented ? 0 : geometry.size.height + 16)
                .opacity(presentation.isPresented ? 1 : 0)
                .animation(presentation.reduceMotion ? .easeOut(duration: 0.10) :
                    (presentation.isPresented ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.28) : .easeIn(duration: 0.18)),
                    value: presentation.isPresented)
        }
        // Clip inside the stationary window, so sliding out cannot bleed onto
        // another monitor placed below this display in the desktop arrangement.
        .clipped()
    }
}

struct ShelfOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 28
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
