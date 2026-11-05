import ClipboardCore

enum ShelfGroupNavigation {
    static let allID = "all"
    static let favoritesID = "favorites"

    static func matches(_ record: ClipRecord, group: String) -> Bool {
        switch group {
        case allID: return true
        case favoritesID: return record.favorite
        default: return record.collectionID == group
        }
    }

    static func target(current: String, collections: [ClipCollection], offset: Int) -> String {
        let ids = [allID, favoritesID] + collections.map(\.id)
        guard let index = ids.firstIndex(of: current) else { return allID }
        return ids[(index + offset % ids.count + ids.count) % ids.count]
    }
}
