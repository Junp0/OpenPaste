import Foundation
import CryptoKit

public enum ClipKind: String, Codable, CaseIterable {
    case text, link, image, file
    public var label: String {
        switch self { case .text: return "文本"; case .link: return "链接"; case .image: return "图片"; case .file: return "文件" }
    }
    public var symbol: String {
        switch self { case .text: return "text.alignleft"; case .link: return "link"; case .image: return "photo"; case .file: return "doc" }
    }
}

public struct ClipRepresentation: Codable, Equatable {
    public let type: String
    public let data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
}

public struct ClipPayload: Codable, Equatable {
    public let items: [[ClipRepresentation]]
    public init(items: [[ClipRepresentation]]) { self.items = items }
    public var fingerprint: String {
        var hasher = SHA256()
        // Length prefixes keep distinct item/type/data boundaries unambiguous.
        func append(_ data: Data) {
            var size = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &size) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        append(Data(String(items.count).utf8))
        for item in items {
            append(Data(String(item.count).utf8))
            for representation in item.sorted(by: { $0.type < $1.type }) {
                append(Data(representation.type.utf8)); append(representation.data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct ClipRecord: Identifiable {
    public let id: String
    public let kind: ClipKind
    public let title: String
    public let text: String
    public let sourceName: String
    public let sourceBundle: String
    public let createdAt: Date
    public let updatedAt: Date
    public let thumbnail: Data?
    public let byteCount: Int
    public let favorite: Bool
    public let collectionID: String?
}

public struct ClipDraft {
    public var kind: ClipKind
    public var title: String
    public var text: String
    public var sourceName: String
    public var sourceBundle: String
    public var thumbnail: Data?
    public var payload: ClipPayload
    public init(kind: ClipKind, title: String, text: String, sourceName: String, sourceBundle: String, thumbnail: Data? = nil, payload: ClipPayload) {
        self.kind = kind; self.title = title; self.text = text; self.sourceName = sourceName
        self.sourceBundle = sourceBundle; self.thumbnail = thumbnail; self.payload = payload
    }
}

public struct ClipCollection: Identifiable, Equatable {
    public static let defaultIcon = "pin.fill"
    public let id: String
    public let name: String
    public let icon: String
    public init(id: String, name: String, icon: String = ClipCollection.defaultIcon) {
        self.id = id; self.name = name; self.icon = icon
    }
}
