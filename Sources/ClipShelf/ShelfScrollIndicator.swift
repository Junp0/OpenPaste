import AppKit
import SwiftUI

struct ShelfScrollMetrics: Equatable {
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
    let offset: CGFloat
}

/// Observe actual wheel/trackpad input, so layout and scrollTo never flash the indicator.
@MainActor final class ShelfScrollActivity: ObservableObject {
    @Published private(set) var contentWidth: CGFloat = 0
    @Published private(set) var viewportWidth: CGFloat = 0
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var isVisible = false
    private var lastInput = -Double.infinity
    private var isInteracting = false
    private var hideTask: DispatchWorkItem?

    func noteInput() { lastInput = ProcessInfo.processInfo.systemUptime }
    func setInteracting(_ value: Bool) { isInteracting = value }

    func update(from scrollView: NSScrollView) {
        update(ShelfScrollMetrics(contentWidth: scrollView.documentView?.frame.width ?? 0,
            viewportWidth: scrollView.contentView.bounds.width, offset: scrollView.contentView.bounds.minX),
            isWindowVisible: scrollView.window?.isVisible == true)
    }

    func update(_ metrics: ShelfScrollMetrics, isWindowVisible: Bool = true) {
        let previousOffset = offset
        contentWidth = metrics.contentWidth
        viewportWidth = metrics.viewportWidth
        offset = metrics.offset
        guard isWindowVisible, contentWidth > viewportWidth + 1,
              abs(offset - previousOffset) > 0.1,
              isInteracting || ProcessInfo.processInfo.systemUptime - lastInput < 0.25 else { return }
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.1)) { isVisible = true }
        let task = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.isVisible = false }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: task)
    }

    func reset() {
        hideTask?.cancel(); hideTask = nil
        lastInput = -Double.infinity
        isInteracting = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isVisible = false }
    }
}

struct ShelfScrollTracking: ViewModifier {
    let activity: ShelfScrollActivity

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: ShelfScrollMetrics.self) { geometry in
                    ShelfScrollMetrics(contentWidth: geometry.contentSize.width,
                        viewportWidth: geometry.containerSize.width, offset: geometry.contentOffset.x)
                } action: { _, metrics in activity.update(metrics) }
                .onScrollPhaseChange { _, phase in
                    activity.setInteracting(phase == .interacting || phase == .decelerating)
                }
        } else {
            content
        }
    }
}

/// Compatibility observer for macOS 13–14, before SwiftUI's scroll geometry API.
struct ShelfScrollObserver: NSViewRepresentable {
    let activity: ShelfScrollActivity

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.activity = activity
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) {}
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: NSView {
        weak var activity: ShelfScrollActivity?
        private weak var observedScrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var wheelMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleAttach() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { scheduleAttach() }
        }
        private func scheduleAttach() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        private func attach() {
            guard window != nil, let scrollView = enclosingScrollView, observedScrollView !== scrollView else { return }
            detach()
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            activity?.update(from: scrollView)
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let scrollView = self.observedScrollView else { return }
                        self.activity?.update(from: scrollView)
                    }
                }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, let scrollView = self.observedScrollView,
                   event.window === scrollView.window,
                   scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)),
                   event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                    self.activity?.noteInput()
                }
                return event
            }
        }
        func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            boundsObserver = nil; wheelMonitor = nil; observedScrollView = nil
            activity?.reset()
        }
    }
}

struct ShelfScrollIndicator: View {
    @ObservedObject var activity: ShelfScrollActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let track = max(0, geometry.size.width - 48)
            let overflow = max(0, activity.contentWidth - activity.viewportWidth)
            let fraction = activity.viewportWidth / max(1, activity.contentWidth)
            let width = min(track, max(44, track * fraction))
            let progress = min(1, max(0, activity.offset / max(1, overflow)))
            Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.16))
                .frame(width: width, height: 3)
                .offset(x: 24 + (track - width) * progress)
                .opacity(activity.isVisible && overflow > 1 ? 1 : 0)
                .transaction { if reduceMotion { $0.animation = nil } }
        }
        .frame(height: 3).padding(.bottom, 4)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
