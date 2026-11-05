import Foundation
import ClipboardCore

struct ClipSearch {
    private static let aliases: [ClipKind: Set<String>] = [
        .image: ["img", "imgs", "image", "images", "pic", "pics", "picture", "pictures", "photo", "photos", "图片", "图像", "照片"],
        .text: ["text", "texts", "txt", "文本", "文字", "纯文本"],
        .link: ["link", "links", "url", "urls", "hyperlink", "hyperlinks", "链接", "网址", "超链接"],
        .file: ["file", "files", "doc", "docs", "document", "documents", "文件", "文档"]
    ]

    private let kinds: Set<ClipKind>
    private let content: String

    init(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var kinds: Set<ClipKind> = []
        var content = ""
        var previousContentEnd: String.Index?
        // Match whole whitespace-delimited words, never parts of filenames or URLs.
        for word in trimmed.split(whereSeparator: \.isWhitespace) {
            if let kind = Self.aliases.first(where: { $0.value.contains(word.lowercased()) })?.key {
                kinds.insert(kind)
                previousContentEnd = nil
            } else {
                if let previousContentEnd {
                    content += trimmed[previousContentEnd..<word.endIndex]
                } else {
                    if !content.isEmpty { content += " " }
                    content += word
                }
                previousContentEnd = word.endIndex
            }
        }
        self.kinds = kinds
        // Preserve the existing substring search when there are no type keywords.
        self.content = kinds.isEmpty ? trimmed : content
    }

    func matches(_ record: ClipRecord) -> Bool {
        (kinds.isEmpty || kinds.contains(record.kind)) &&
        (content.isEmpty || record.title.localizedStandardContains(content) ||
            record.text.localizedStandardContains(content) || record.sourceName.localizedStandardContains(content))
    }
}
