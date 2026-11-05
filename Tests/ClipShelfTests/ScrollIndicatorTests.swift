import Testing
@testable import ClipShelf

@Suite @MainActor struct ScrollIndicatorTests {
    private func metrics(offset: Double, contentWidth: Double = 2400) -> ShelfScrollMetrics {
        ShelfScrollMetrics(contentWidth: contentWidth, viewportWidth: 1200, offset: offset)
    }

    @Test func initialLayoutAndKeyboardScrollingDoNotFlash() {
        let activity = ShelfScrollActivity()
        activity.update(metrics(offset: 0))
        activity.update(metrics(offset: 600))
        #expect(!activity.isVisible)
        #expect(activity.offset == 600)
    }

    @Test func userScrollShowsButReopeningImmediatelyHides() {
        let activity = ShelfScrollActivity()
        activity.update(metrics(offset: 0))
        activity.setInteracting(true)
        activity.update(metrics(offset: 200))
        #expect(activity.isVisible)
        activity.reset()
        #expect(!activity.isVisible)
        // The panel's scrollTo reset must not bring the old indicator back.
        activity.update(metrics(offset: 0))
        #expect(!activity.isVisible)
    }

    @Test func wheelInputRequiresMovementAndOverflow() {
        let activity = ShelfScrollActivity()
        activity.update(metrics(offset: 0))
        activity.noteInput()
        activity.update(metrics(offset: 0))
        #expect(!activity.isVisible)
        activity.update(metrics(offset: 100))
        #expect(activity.isVisible)
        activity.reset()
        activity.noteInput()
        activity.update(metrics(offset: 0, contentWidth: 800))
        #expect(!activity.isVisible)
    }

    @Test func stoppingScrollAutomaticallyHides() async throws {
        let activity = ShelfScrollActivity()
        activity.update(metrics(offset: 0))
        activity.setInteracting(true)
        activity.update(metrics(offset: 200))
        activity.setInteracting(false)
        #expect(activity.isVisible)
        try await Task.sleep(for: .milliseconds(900))
        #expect(!activity.isVisible)
    }
}
