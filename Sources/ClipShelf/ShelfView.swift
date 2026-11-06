import SwiftUI
import AppKit
import ClipboardCore
import UniformTypeIdentifiers

private let shelfAccent = IPasteStyle.accent

extension ClipKind {
    var color: Color {
        switch self { case .text: return Color(red: 0.31, green: 0.46, blue: 0.83)
        case .link: return Color(red: 0.47, green: 0.36, blue: 0.75)
        case .image: return Color(red: 0.23, green: 0.58, blue: 0.45)
        case .file: return Color(red: 0.78, green: 0.49, blue: 0.19) }
    }
}

struct ShelfView: View {
    @ObservedObject var store: ClipboardStore
    let searchInput: SearchInputController
    let paste: (ClipRecord, Bool) -> Void
    let copy: (ClipRecord) -> Void
    let showSettings: () -> Void
    let dismiss: () -> Void
    @ViewState<String?> private var highlightedDropGroup: String?
    @ViewState<String> private var newCollectionIcon = ClipCollection.defaultIcon
    @StateObject private var scrollActivity = ShelfScrollActivity()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if store.visibleRecords.isEmpty { emptyState }
            else { cards }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IPastePanelBackground())
        .clipShape(ShelfOutline())
        .overlay(ShelfOutline().stroke(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.08)],
            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1).allowsHitTesting(false))
        .tint(shelfAccent)
        .allowsHitTesting(store.previewID == nil)
        .accessibilityHidden(store.previewID != nil)
        .overlay {
            GeometryReader { geometry in
                if let record = store.records.first(where: { $0.id == store.previewID }) {
                    ZStack {
                        Color.black.opacity(0.12)
                            .contentShape(Rectangle())
                            .onTapGesture { store.previewID = nil }
                        PreviewView(record: record, store: store, copy: { copy(record) },
                            paste: { paste(record, false) },
                            dismiss: { store.previewID = nil })
                            .frame(width: min(700, max(1, geometry.size.width - 32)),
                                height: min(500, max(1, geometry.size.height - 32)))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onAppear { searchInput.blur() }
                }
            }
            .clipShape(ShelfOutline())
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusShelfSearch)) { _ in searchInput.focus() }
        .onChange(of: store.draggedRecordID) { id in if id == nil { highlightedDropGroup = nil } }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var toolbar: some View {
        IPasteGlassContainer {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .renderingMode(.original).resizable().interpolation(.high)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    Text("OpenPaste").font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                .padding(.trailing, 10).help("OpenPaste · 你的下一次粘贴，随手可得")
                groupTabs
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.secondary)
                    SearchInput(text: $store.query, controller: searchInput).frame(height: 20)
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(IPasteButtonStyle(in: Circle(), glass: false)).help("清空搜索")
                    } else {
                        Text("⌘F").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 15).frame(width: 250, height: 38)
                    .ipasteGlass(in: Capsule())
                toolbarButton(store.paused ? "play.fill" : "pause.fill", help: store.paused ? "继续记录" : "暂停记录",
                              tint: store.paused ? .orange : nil) { store.paused.toggle() }
                toolbarButton("gearshape", help: "设置 ⌘,", action: showSettings)
                toolbarButton("xmark", help: "关闭 \(store.shortcutLabel) / ⌘↓ / Esc", action: dismiss)
            }
        }
        .font(.system(size: 14)).buttonStyle(.plain)
        .padding(.horizontal, 24).padding(.top, 19).padding(.bottom, 18)
    }

    private func toolbarButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 38, height: 38).contentShape(Circle())
        }
        .buttonStyle(IPasteButtonStyle(in: Circle(), tint: tint))
        .accessibilityLabel(help).help(help)
    }

    private var groupTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    groupTab("全部记录", id: "all", symbol: "clock.arrow.circlepath")
                    groupTab("收藏", id: ShelfGroupNavigation.favoritesID, symbol: "star.fill")
                    ForEach(store.collections) { collection in
                        groupTab(collection.name, id: collection.id, symbol: collection.icon)
                            .contextMenu {
                                Button("删除分组（保留内容）") { store.deleteCollection(id: collection.id) }
                            }
                    }
                    if store.isCreatingCollection {
                        InlineGroupNameInput(icon: $newCollectionIcon, onFinish: finishCollectionCreation)
                            .frame(width: 190, height: 24)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .ipasteGlass(in: Capsule(), tint: shelfAccent.opacity(0.2))
                            .help("回车创建，Esc 取消；留空不创建")
                            .id("new-collection-editor")
                    } else {
                        Button {
                            newCollectionIcon = ClipCollection.defaultIcon
                            store.isCreatingCollection = true
                        } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary).frame(width: 36, height: 36)
                        }.buttonStyle(IPasteButtonStyle(in: Circle()))
                            .accessibilityLabel("新建分组").help("新建分组")
                    }
                }.padding(.horizontal, 4).padding(.vertical, 5)
            }
            .onChange(of: store.filter) { id in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: store.isCreatingCollection) { editing in
                if editing { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("new-collection-editor", anchor: .trailing) } }
            }
        }.frame(maxWidth: .infinity).frame(height: 46)
    }

    private func groupTab(_ title: String, id: String, symbol: String) -> some View {
        let active = store.filter == id
        let dropTarget = highlightedDropGroup == id
        return Button { store.filter = id } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                Text("\(store.count(for: id))").font(.system(size: 10, weight: .medium, design: .rounded)).opacity(0.65)
            }
            .padding(.horizontal, 14).frame(height: 36)
            .foregroundStyle(active || dropTarget ? shelfAccent : Color.primary.opacity(0.75))
            .contentShape(Capsule())
        }.buttonStyle(IPasteButtonStyle(in: Capsule(),
            tint: active || dropTarget ? shelfAccent.opacity(dropTarget ? 0.35 : 0.18) : nil))
            .accessibilityAddTraits(active ? .isSelected : [])
            .overlay(Capsule().strokeBorder(dropTarget ? shelfAccent : .clear, lineWidth: 2).allowsHitTesting(false))
            .onDrop(of: [UTType.clipShelfRecord], delegate: GroupDropDelegate(store: store, groupID: id, highlightedGroup: $highlightedDropGroup))
            .help("\(title) · 拖入卡片归类 · ⌘← / ⌘→ 切换分组").id(id)
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array(store.visibleRecords.enumerated()), id: \.element.id) { index, record in
                        ClipCard(record: record, store: store, index: index, selected: store.selectedID == record.id, size: store.displaySize,
                            select: { searchInput.blur(); store.selectCard(record) },
                            paste: { paste(record, false) }, favorite: { store.favorite(record) })
                            .id(record.id)
                            .onDrag {
                                searchInput.blur()
                                store.beginClipDrag(record)
                                return ClipDragItem.provider(recordID: record.id)
                            } preview: {
                                ClipDragPreview(record: record, store: store)
                            }
                            .modifier(ClipDragLifecycle(store: store))
                            .contextMenu { cardMenu(record) }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("\(record.kind.label)：\(record.title)")
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .identity,
                                removal: .opacity.combined(with: .scale(scale: 0.88)).combined(with: .offset(y: 16))))
                    }
                }.padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 16)
                    .background {
                        if #unavailable(macOS 15.0) { ShelfScrollObserver(activity: scrollActivity) }
                    }
            }
            .scrollIndicators(.never)
            .modifier(ShelfScrollTracking(activity: scrollActivity))
            .overlay(alignment: .bottom) { ShelfScrollIndicator(activity: scrollActivity) }
            .onReceive(NotificationCenter.default.publisher(for: .shelfDidShow)) { _ in
                scrollActivity.reset()
                scrollToSelectionOnShow(proxy)
            }
            .onAppear { scrollToSelectionOnShow(proxy) }
            .onDisappear { scrollActivity.reset() }
            .onChange(of: store.selectedID) { value in
                if let value, store.selectionOrigin != .pointer {
                    let followsDeletion = store.selectionOrigin == .deletion
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: followsDeletion ? 0.24 : 0.15)) {
                        // After a deletion, scroll only as far as necessary to
                        // reveal the neighbor instead of recentering the shelf.
                        proxy.scrollTo(value, anchor: followsDeletion ? nil : .center)
                    }
                }
            }
        }.frame(maxHeight: .infinity)
    }
    private func scrollToSelectionOnShow(_ proxy: ScrollViewProxy) {
        guard let id = store.selectedID else { return }
        // Pasting keeps the selected ID while moving its record to the front.
        // Reopening must restore the viewport even when onChange cannot fire.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
    }
    @ViewBuilder private func cardMenu(_ record: ClipRecord) -> some View {
        Button("粘贴") { paste(record, false) }
        if !record.text.isEmpty { Button("粘贴为纯文本") { paste(record, true) } }
        Button("复制到剪贴板") { copy(record) }
        Button("预览内容") { store.previewID = record.id }
        Divider()
        Button(record.favorite ? "取消收藏" : "加入收藏") { store.favorite(record) }
        Menu("移至分组") {
            Button("不分组") { store.assign(nil, record: record) }
            ForEach(store.collections) { collection in
                Button(collection.name) { store.assign(collection.id, record: record) }
            }
        }
        if record.kind == .link, let url = URL(string: record.text) { Button("在浏览器中打开") { NSWorkspace.shared.open(url) } }
        Divider()
        Button("删除记录", role: .destructive) { store.delete(record) }
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: store.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 30, weight: .light)).foregroundStyle(shelfAccent)
                .frame(width: 76, height: 76).ipasteGlass(in: RoundedRectangle(cornerRadius: 24))
                .padding(.bottom, 7)
            Text(emptyTitle).font(.system(size: 17, weight: .semibold))
            Text(emptyDescription).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            if store.paused {
                Button("继续记录") { store.paused = false }
                    .buttonStyle(IPasteButtonStyle(in: Capsule(), horizontalPadding: 15, verticalPadding: 8))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }
    private var emptyTitle: String {
        if !store.query.isEmpty { return "没有找到匹配的内容" }
        if store.filter == ShelfGroupNavigation.favoritesID { return "还没有收藏内容" }
        if store.filter != "all" { return "这个分组还是空的" }
        return "下一次复制，就从这里找回"
    }
    private var emptyDescription: String {
        if !store.query.isEmpty { return "试试其他关键词，或切换分组。" }
        if store.filter == ShelfGroupNavigation.favoritesID { return "点击卡片右上角的星标，常用内容就会出现在这里。" }
        if store.filter != "all" { return "右键点击一张卡片，选择「移至分组」。" }
        return "在其他应用中复制文本、链接或图片\n按 \(store.shortcutLabel) 回来，随时取用。"
    }
    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(store.paused ? .orange : .green).frame(width: 5, height: 5)
                Text(store.paused ? "记录已暂停" : store.message).lineLimit(1)
            }
            Text("\(store.visibleRecords.count) 条内容").monospacedDigit().fixedSize()
            Spacer(minLength: 8)
            Text("← → 选择").fixedSize()
            Text("⌘← → 分组").fixedSize()
            Text("空格 预览").fixedSize()
            Text("⌫ 删除").fixedSize()
            Text("↵ 粘贴").fixedSize()
            Text("⌘1–9 快速粘贴").fixedSize()
        }.font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 16)
    }
    private func finishCollectionCreation(_ result: InlineGroupEditResult) {
        guard store.isCreatingCollection else { return }
        store.isCreatingCollection = false
        switch result {
        case .submitted(let name):
            store.addCollection(name: name, icon: newCollectionIcon)
            searchInput.focus(caretAtEnd: true)
        case .lostFocus(let name):
            store.addCollection(name: name, icon: newCollectionIcon, select: false)
        case .cancelled:
            searchInput.focus(caretAtEnd: true)
        }
    }
}

private struct ClipCard: View {
    let record: ClipRecord
    let store: ClipboardStore
    let index: Int
    let selected: Bool
    let size: ShelfDisplaySize
    let select: () -> Void
    let paste: () -> Void
    let favorite: () -> Void
    @ViewState<Bool> private var hovering = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: record.kind.symbol).font(.system(size: size.bodyFontSize - 1, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(record.kind.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                Text(record.kind.label).font(.system(size: size.bodyFontSize - 1, weight: .semibold))
                Spacer()
                Button(action: favorite) {
                    Image(systemName: record.favorite ? "star.fill" : "star")
                        .font(.system(size: size.bodyFontSize)).foregroundStyle(record.favorite ? Color.orange : record.kind.color.opacity(0.8))
                        .frame(width: 28, height: 28).contentShape(Circle())
                }.buttonStyle(IPasteButtonStyle(in: Circle(), tint: .orange, glass: false))
                    .accessibilityLabel(record.favorite ? "取消收藏" : "加入收藏")
                    .help(record.favorite ? "取消收藏" : "加入收藏")
            }.foregroundStyle(record.kind.color).padding(15)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                sourceIcon
                Text(record.sourceName).lineLimit(1)
                Spacer(minLength: 2)
                Text(record.updatedAt, style: .relative).lineLimit(1)
                if index < 9 {
                    Text("⌘\(index + 1)").font(.system(size: size.sourceFontSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(selected ? shelfAccent : .secondary)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                }
            }.font(.system(size: size.sourceFontSize)).foregroundStyle(.secondary).padding(.horizontal, 13).frame(height: size.footerHeight)
        }
        .frame(width: size.cardWidth, height: size.cardHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(reduceTransparency ? 1 : 0.88))
        .background(LinearGradient(colors: [record.kind.color.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: IPasteStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: IPasteStyle.cardRadius, style: .continuous)
            .strokeBorder(selected ? shelfAccent.opacity(0.85) : Color.primary.opacity(hovering ? 0.2 : 0.08), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(selected ? 0.10 : 0.05), radius: selected || hovering ? 10 : 5, y: 4)
        .offset(y: hovering && !reduceMotion ? -2 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: IPasteStyle.cardRadius))
        // Recognize selection alongside the double tap instead of waiting for
        // the double-click interval to expire. Keep this a normal parent gesture
        // so the favorite button can handle its own clicks.
        .gesture(TapGesture().onEnded { select() }
            .simultaneously(with: TapGesture(count: 2).onEnded { paste() }))
        .onHover { hovering = $0 }
        .help("拖到顶部分组归类；单击选择，双击粘贴；右键查看更多操作")
    }
    @ViewBuilder private var content: some View {
        if record.kind == .image {
            ZStack {
                record.kind.color.opacity(0.025)
                ClipThumbnailView(record: record, store: store).padding(9)
                VStack { Spacer(); HStack { Text(record.title).font(.system(size: size.sourceFontSize, design: .monospaced)).padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4)); Spacer() } }.padding(9)
            }
        } else if record.kind == .link {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "globe").font(.system(size: 27, weight: .light)).foregroundStyle(record.kind.color)
                Text(record.title).font(.system(size: size.bodyFontSize + 4, weight: .semibold)).lineLimit(2)
                Text(String(record.text.prefix(400))).font(.system(size: size.bodyFontSize - 1)).foregroundStyle(.secondary).lineLimit(4)
            }.padding(16)
        } else if record.kind == .file {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "doc.fill").font(.system(size: 31)).foregroundStyle(record.kind.color.opacity(0.7))
                Text(record.title).font(.system(size: size.bodyFontSize + 2, weight: .medium)).lineLimit(2)
                Text(record.text).font(.system(size: size.bodyFontSize - 2)).foregroundStyle(.secondary).lineLimit(3)
            }.padding(16)
        } else {
            Text(record.text.isEmpty ? record.title : String(record.text.prefix(2000)))
                .font(.system(size: size.bodyFontSize)).lineSpacing(5).foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
        }
    }
    @ViewBuilder private var sourceIcon: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.sourceBundle) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: size.sourceFontSize + 4, height: size.sourceFontSize + 4)
        } else { Image(systemName: "app").frame(width: size.sourceFontSize + 4, height: size.sourceFontSize + 4) }
    }
}

private struct PreviewView: View {
    let record: ClipRecord
    @ObservedObject var store: ClipboardStore
    let copy: () -> Void
    let paste: () -> Void
    let dismiss: () -> Void
    @ViewState<NSImage?> private var image: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: record.kind.symbol).foregroundStyle(record.kind.color)
                Text(record.title).font(.headline).lineLimit(1)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(IPasteButtonStyle(in: Capsule(), horizontalPadding: 15, verticalPadding: 8))
            }
            if record.kind == .image {
                if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { Text("无法读取图片预览").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                ScrollView { Text(record.text.isEmpty ? "此内容仅包含富文本格式，可复制后粘贴查看。" : record.text)
                    .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Text("\(record.sourceName) · \(record.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制内容") { copy(); dismiss() }
                    .buttonStyle(IPasteButtonStyle(in: Capsule(), horizontalPadding: 16, verticalPadding: 9))
                Button("粘贴内容", action: paste).keyboardShortcut(.defaultAction)
                    .buttonStyle(IPasteButtonStyle(in: Capsule(), tint: shelfAccent.opacity(0.2),
                        horizontalPadding: 16, verticalPadding: 9))
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IPastePanelBackground()).tint(shelfAccent)
            .onAppear { image = store.previewImage(for: record) }
            .onDisappear { image = nil }
    }
}
