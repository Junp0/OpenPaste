import AppKit
import ClipboardCore
import Testing
@testable import ClipShelf

@Suite @MainActor struct ClipSearchTests {
    private func withStore(_ body: (ClipboardStore, String) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(dataDirectory: directory, monitorsClipboard: false)
        let group = try store.database.addCollection(name: "工作")
        for (index, kind) in ([ClipKind.image] + ClipKind.allCases).enumerated() {
            let id = try store.database.save(ClipDraft(kind: kind,
                title: "共享标题 image text link file \(index)",
                text: "正文 image.png myimage https://example.test/image 双  空格",
                sourceName: index == 0 ? "Finder" : "Safari", sourceBundle: "test.app",
                payload: ClipPayload(items: [[ClipRepresentation(type: "test", data: Data("\(index)".utf8))]])),
                now: Date().addingTimeInterval(Double(index)))
            if kind == .image && index != 0 {
                try store.database.assign(group, to: id)
                try store.database.setFavorite(true, id: id)
            }
        }
        try store.reload()
        try body(store, group)
    }

    @Test func typeAliasesFilterByKindEvenWhenOtherRecordsContainTheKeyword() throws {
        try withStore { store, _ in
            let aliases: [(ClipKind, [String])] = [
                (.image, ["img", "imgs", "image", "images", "pic", "pics", "picture", "pictures", "photo", "photos", "图片", "图像", "照片"]),
                (.text, ["text", "texts", "txt", "文本", "文字", "纯文本"]),
                (.link, ["link", "links", "url", "urls", "hyperlink", "hyperlinks", "链接", "网址", "超链接"]),
                (.file, ["file", "files", "doc", "docs", "document", "documents", "文件", "文档"])
            ]
            for (kind, keywords) in aliases {
                let expected = store.records.filter { $0.kind == kind }.map(\.id)
                for keyword in keywords {
                    store.query = " \n\(keyword.uppercased())\t "
                    #expect(store.visibleRecords.map(\.id) == expected, "Keyword: \(keyword)")
                }
            }
        }
    }

    @Test func typeAndContentOrSourceCombineWithinTheSameRecord() throws {
        try withStore { store, _ in
            let image = try #require(store.records.first { $0.kind == .image && $0.sourceName == "Safari" })
            for query in ["img Safari", "Safari 图片", "IMG\tSafari", "image 图片 Safari"] {
                store.query = query
                #expect(store.visibleRecords.map(\.id) == [image.id])
            }
            store.query = "文件 共享标题"
            #expect(store.visibleRecords.map(\.kind) == [.file])
            store.query = "url 正文"
            #expect(store.visibleRecords.map(\.kind) == [.link])
            store.query = "text 双  空格"
            #expect(store.visibleRecords.map(\.kind) == [.text])
            store.query = "text 不存在"
            #expect(store.visibleRecords.isEmpty)
            #expect(store.selectedID == nil)
        }
    }

    @Test func multipleTypesFormAUnionAndKeepExistingRecencyOrder() throws {
        try withStore { store, _ in
            store.query = "img link 图片"
            #expect(store.visibleRecords.map(\.id) == store.records.filter { [.image, .link].contains($0.kind) }.map(\.id))
            store.query = "图片 url Safari"
            #expect(store.visibleRecords.map(\.kind) == [.image, .link])
        }
    }

    @Test func ordinarySubstringsAndEmptyQueriesKeepExistingSearchBehavior() throws {
        try withStore { store, _ in
            for query in ["image.png", "myimage", "https://example.test/image", "双  空格", "共享标题", "正文", "", " \n\t "] {
                store.query = query
                #expect(store.visibleRecords.map(\.id) == store.records.map(\.id), "Query: \(query)")
            }
            store.query = "safari"
            #expect(store.visibleRecords.count == 4)
            store.query = "imag"
            #expect(store.visibleRecords.count == 5)
            store.query = "不存在"
            #expect(store.visibleRecords.isEmpty)
        }
    }

    @Test func typeSearchRespectsGroupsFavoritesSelectionAndClearing() throws {
        try withStore { store, group in
            let image = try #require(store.records.first { $0.collectionID == group })
            let file = try #require(store.records.first { $0.kind == .file })
            store.selectedID = file.id
            store.query = "img"
            #expect(store.selectedID == image.id)
            store.filter = group
            #expect(store.visibleRecords.map(\.id) == [image.id])
            store.query = "file"
            #expect(store.visibleRecords.isEmpty)
            #expect(store.selectedID == nil)
            store.filter = ShelfGroupNavigation.favoritesID
            #expect(store.visibleRecords.isEmpty)
            store.query = "图片"
            #expect(store.visibleRecords.map(\.id) == [image.id])
            #expect(store.selectedID == image.id)
            store.query = ""
            #expect(store.filter == ShelfGroupNavigation.favoritesID)
            #expect(store.visibleRecords.map(\.id) == [image.id])
            store.filter = ShelfGroupNavigation.allID
            #expect(store.visibleRecords.count == 5)
            #expect(store.selectedID == image.id)
        }
    }
}
