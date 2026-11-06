import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClipboardCore

extension UTType {
    static let clipShelfRecord = UTType(exportedAs: "io.clipshelf.clip-record", conformingTo: .data)
}

enum ClipGroupDropOperation: Equatable {
    case addFavorite, removeGroup, move(String)

    static func resolve(target: String, collections: [ClipCollection]) -> Self? {
        if target == ShelfGroupNavigation.favoritesID { return .addFavorite }
        if target == ShelfGroupNavigation.allID { return .removeGroup }
        return collections.contains(where: { $0.id == target }) ? .move(target) : nil
    }
    func apply(recordID: String, database: ClipboardDatabase) throws {
        switch self {
        case .addFavorite: try database.setFavorite(true, id: recordID)
        case .removeGroup: try database.assign(nil, to: recordID)
        case .move(let group): try database.assign(group, to: recordID)
        }
    }
}

enum ClipDragItem {
    static func provider(recordID: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.clipShelfRecord.identifier, visibility: .ownProcess) { complete in
            complete(Data(recordID.utf8), nil)
            return nil
        }
        return provider
    }
}

struct ClipDragPreview: View {
    let record: ClipRecord
    let store: ClipboardStore

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(record.kind.label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .frame(width: 156, height: 54)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(record.kind.color.opacity(0.4)))
        .compositingGroup()
        .opacity(0.65)
    }

    @ViewBuilder private var thumbnail: some View {
        if record.kind == .image {
            ClipThumbnailView(record: record, store: store)
        } else {
            ZStack {
                record.kind.color.opacity(0.12)
                Image(systemName: record.kind.symbol)
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(record.kind.color)
            }
        }
    }
}

struct ClipDragLifecycle: ViewModifier {
    let store: ClipboardStore

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .dragConfiguration(DragConfiguration(operationsWithinApp: .init(allowMove: true), operationsOutsideApp: .init(allowCopy: false)))
                .onDragSessionUpdated { session in
                switch session.phase {
                case .ended(_):
                    // Successful local drops have already committed and ended.
                    // This also clears cancellation and drops outside the shelf.
                    store.endClipDrag(completedInside: false)
                // Providers may finish transferring data before the user drops.
                // Only the session's ended phase means the gesture has finished.
                default: break
                }
            }
        } else { content }
    }
}

struct GroupDropDelegate: DropDelegate {
    let store: ClipboardStore
    let groupID: String
    @Binding var highlightedGroup: String?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.clipShelfRecord]) && store.canDropDraggedRecord(to: groupID)
    }
    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { highlightedGroup = groupID }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: groupID == ShelfGroupNavigation.favoritesID ? .copy : .move)
    }
    func dropExited(info: DropInfo) {
        if highlightedGroup == groupID { highlightedGroup = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        highlightedGroup = nil
        return store.dropDraggedRecord(to: groupID)
    }
}
