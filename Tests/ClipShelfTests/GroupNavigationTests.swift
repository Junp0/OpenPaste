import AppKit
import Carbon
import ClipboardCore
import Testing
@testable import ClipShelf

@Suite @MainActor struct GroupNavigationTests {
    private func event(_ code: UInt16, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }
    @Test func groupsFollowVisibleOrderAndWrapBothWays() {
        let groups = [ClipCollection(id: "work", name: "工作"), ClipCollection(id: "ideas", name: "灵感")]
        #expect(ShelfGroupNavigation.target(current: "all", collections: groups, offset: 1) == "favorites")
        #expect(ShelfGroupNavigation.target(current: "favorites", collections: groups, offset: 1) == "work")
        #expect(ShelfGroupNavigation.target(current: "work", collections: groups, offset: 1) == "ideas")
        #expect(ShelfGroupNavigation.target(current: "ideas", collections: groups, offset: 1) == "all")
        #expect(ShelfGroupNavigation.target(current: "all", collections: groups, offset: -1) == "ideas")
        #expect(ShelfGroupNavigation.target(current: "work", collections: groups, offset: -1) == "favorites")
        #expect(ShelfGroupNavigation.target(current: "favorites", collections: groups, offset: -1) == "all")
        #expect(ShelfGroupNavigation.target(current: "all", collections: groups, offset: 4) == "all")
    }
    @Test func builtInGroupsRemainWithoutCustomGroupsAndDeletedGroupsFallBack() {
        #expect(ShelfGroupNavigation.target(current: "all", collections: [], offset: 1) == "favorites")
        #expect(ShelfGroupNavigation.target(current: "all", collections: [], offset: -1) == "favorites")
        #expect(ShelfGroupNavigation.target(current: "favorites", collections: [], offset: 1) == "all")
        #expect(ShelfGroupNavigation.target(current: "deleted", collections: [], offset: 1) == "all")
        let groups = [ClipCollection(id: "work", name: "工作")]
        #expect(ShelfGroupNavigation.target(current: "deleted", collections: groups, offset: -1) == "all")
    }
    @Test func favoritesAggregateStarredRecordsWithoutChangingCustomGroups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ClipboardDatabase(url: directory.appendingPathComponent("history.sqlite"))
        let group = try database.addCollection(name: "工作")
        var ids: [String] = []
        for text in ["已分组的收藏", "未分组的收藏", "普通记录"] {
            ids.append(try database.save(ClipDraft(kind: .text, title: text, text: text, sourceName: "Test", sourceBundle: "test.app",
                payload: ClipPayload(items: [[ClipRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]]))))
        }
        try database.assign(group, to: ids[0])
        try database.setFavorite(true, id: ids[0]); try database.setFavorite(true, id: ids[1])
        var records = try database.records()
        #expect(Set(records.filter { ShelfGroupNavigation.matches($0, group: "favorites") }.map(\.id)) == Set(ids.prefix(2)))
        #expect(records.filter { ShelfGroupNavigation.matches($0, group: group) }.map(\.id) == [ids[0]])
        #expect(records.filter { ShelfGroupNavigation.matches($0, group: "all") }.count == 3)
        try database.setFavorite(false, id: ids[0])
        records = try database.records()
        #expect(records.filter { ShelfGroupNavigation.matches($0, group: "favorites") }.map(\.id) == [ids[1]])
        #expect(records.filter { ShelfGroupNavigation.matches($0, group: group) }.map(\.id) == [ids[0]])
        #expect(records.count == 3)
    }
    @Test func commandArrowsCycleGroupsAndCommandDownCloses() throws {
        #expect(ShelfPanelKeyAction.matching(try event(123), shortcut: .standard) == .previousGroup)
        #expect(ShelfPanelKeyAction.matching(try event(124), shortcut: .standard) == .nextGroup)
        #expect(ShelfPanelKeyAction.matching(try event(125), shortcut: .standard) == .dismiss)
        #expect(ShelfPanelKeyAction.matching(try event(123, flags: []), shortcut: .standard) == nil)
        #expect(ShelfPanelKeyAction.matching(try event(124, flags: [.command, .shift]), shortcut: .standard) == nil)
    }
    @Test func repeatingWakeShortcutDismissesAndCustomShortcutTakesPriority() throws {
        #expect(ShelfShortcut.standard.keyCode == UInt32(kVK_UpArrow))
        #expect(ShelfShortcut.standard.modifiers == UInt32(cmdKey))
        #expect(ShelfPanelKeyAction.matching(try event(126), shortcut: .standard) == .dismiss)
        let custom = ShelfShortcut(keyCode: 123, modifiers: UInt32(cmdKey))
        #expect(ShelfPanelKeyAction.matching(try event(123), shortcut: custom) == .dismiss)
        #expect(ShelfPanelKeyAction.matching(try event(126), shortcut: custom) == nil)
    }
}
