import AppKit
import SwiftUI
import KeepsAPI

struct DirectoryOutlineView: NSViewRepresentable {
    @ObservedObject var library: LibraryStore
    @Environment(\.openWindow) private var openWindow

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(library: library)
        coordinator.openTaskWindow = { openWindow(id: "nas-tasks") }
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = DirectoryOutline()
        outline.contextMenuForItem = { [weak coordinator = context.coordinator] item in
            coordinator?.contextMenu(for: item)
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("directory"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.autoresizingMask = [.width]
        outline.headerView = nil
        outline.rowHeight = 30
        outline.indentationPerLevel = 14
        outline.style = .plain
        outline.draggingDestinationFeedbackStyle = .none
        outline.backgroundColor = NSColor(white: 0.17, alpha: 1)
        outline.appearance = NSAppearance(named: .darkAqua)
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = true
        outline.registerForDraggedTypes([Coordinator.directoryDragType, NSPasteboard.PasteboardType(PhotoDragPayload.pasteboardType)])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = outline
        context.coordinator.outline = outline
        context.coordinator.update()
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.library = library
        context.coordinator.update()
    }

    final class DirectoryOutline: NSOutlineView {
        var contextMenuForItem: ((Any) -> NSMenu?)?
        private(set) var dropTargetRow = -1
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            let location = convert(point, from: superview)
            let index = row(at: location)
            // 目录整行统一接收鼠标事件；状态行保留重试按钮的原生交互。
            if index >= 0, item(atRow: index) is Coordinator.Node { return self }
            return hit
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                rightMouseDown(with: event)
                return
            }
            let location = convert(event.locationInWindow, from: nil)
            let index = row(at: location)
            if index >= 0, let item = item(atRow: index), isExpandable(item),
               frameOfOutlineCell(atRow: index).contains(location) {
                if isItemExpanded(item) {
                    if delegate?.outlineView?(self, shouldCollapseItem: item) != false { collapseItem(item) }
                } else {
                    if delegate?.outlineView?(self, shouldExpandItem: item) != false { expandItem(item) }
                }
                return
            }
            super.mouseDown(with: event)
        }

        func highlightDropTarget(row: Int) {
            if dropTargetRow != row {
                if dropTargetRow >= 0, dropTargetRow < numberOfRows {
                    (view(atColumn: 0, row: dropTargetRow, makeIfNecessary: false) as? DirectoryCell)?.nameLabel.isDropTarget = false
                }
                dropTargetRow = row
            }
            if row >= 0 {
                (view(atColumn: 0, row: row, makeIfNecessary: true) as? DirectoryCell)?.nameLabel.isDropTarget = true
            }
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            super.draggingExited(sender)
            highlightDropTarget(row: -1)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            super.draggingEnded(sender)
            highlightDropTarget(row: -1)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { highlightDropTarget(row: -1) }
            return super.performDragOperation(sender)
        }

        override func keyDown(with event: NSEvent) {
            if event.charactersIgnoringModifiers?.lowercased() == "a", event.modifierFlags.contains(.control) {
                selectAll(nil)
            } else if event.keyCode == 53 {
                deselectAll(nil)
            } else { super.keyDown(with: event) }
        }

        override func resize(withOldSuperviewSize oldSize: NSSize) {
            super.resize(withOldSuperviewSize: oldSize)
            sizeLastColumnToFit()
        }

        override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
            let rect = super.frameOfCell(atColumn: column, row: row)
            // 目录层级只缩进左侧，计数始终对齐侧栏右侧的同一条边线。
            let visibleWidth = enclosingScrollView?.contentSize.width ?? bounds.width
            let rightEdge = visibleWidth - 14
            let leftEdge = min(rect.origin.x, max(0, rightEdge - 100))
            return NSRect(x: leftEdge, y: rect.origin.y, width: max(0, rightEdge - leftEdge), height: rect.height)
        }

        override func frameOfOutlineCell(atRow row: Int) -> NSRect {
            var rect = super.frameOfOutlineCell(atRow: row)
            let visibleWidth = enclosingScrollView?.contentSize.width ?? bounds.width
            rect.origin.x = min(rect.minX, max(0, visibleWidth - 114 - rect.width))
            return rect
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let index = row(at: convert(event.locationInWindow, from: nil))
            guard index >= 0, let item = item(atRow: index) else { return nil }
            return contextMenuForItem?(item)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = menu(for: event) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    final class DirectoryNameLabel: NSTextField {
        var isDropTarget = false { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            if isDropTarget {
                let width = min(bounds.width, intrinsicContentSize.width + 4)
                let rect = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
                NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.80, alpha: 1).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
            super.draw(dirtyRect)
        }
    }

    final class DirectoryCell: NSTableCellView {
        let nameLabel = DirectoryNameLabel(labelWithString: "")
        let spinner = NSProgressIndicator()
        let countLabel = NSTextField(labelWithString: "")
        let icon = NSImageView()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let label = nameLabel
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 12)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            countLabel.font = .systemFont(ofSize: 11)
            countLabel.alignment = .right
            countLabel.textColor = .secondaryLabelColor
            countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            countLabel.setContentHuggingPriority(.required, for: .horizontal)
            countLabel.toolTip = "包含所有子目录的照片总数（当前目录照片数），数量相同时仅显示总数；不含回收站"
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            for view in [label, countLabel, icon, spinner] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            textField = label; imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16),
                spinner.leadingAnchor.constraint(equalTo: icon.leadingAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor), spinner.widthAnchor.constraint(equalToConstant: 16), spinner.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: centerYAnchor),
                countLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6), countLabel.trailingAnchor.constraint(equalTo: trailingAnchor), countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        func configure(_ directory: KeepsNavigationDirectory, loading: Bool, hidden: Bool = false) {
            icon.image = NSImage(systemSymbolName: hidden ? "folder.badge.minus" : "folder", accessibilityDescription: hidden ? "隐藏目录" : "目录")
            nameLabel.stringValue = directory.name
            nameLabel.textColor = hidden ? .secondaryLabelColor : .labelColor
            icon.contentTintColor = hidden ? .tertiaryLabelColor : .secondaryLabelColor
            countLabel.textColor = hidden ? .tertiaryLabelColor : .secondaryLabelColor
            countLabel.stringValue = directory.photoCountLabel
            toolTip = directory.path + (hidden ? "（隐藏目录：仅进入此目录或其子目录时显示内容）" : "")
            icon.isHidden = loading
            spinner.isHidden = !loading
            if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        final class Node: NSObject {
            let path: String
            init(_ path: String) { self.path = path }
        }
        final class StatusNode: NSObject {
            let parent: String
            init(_ parent: String) { self.parent = parent }
        }
        final class RetryButton: NSButton { var path = "" }

        static let directoryDragType = NSPasteboard.PasteboardType("com.keeps.directory")
        private var dragGeneration: Int?
        var library: LibraryStore
        var openTaskWindow: (() -> Void)?
        weak var outline: NSOutlineView?
        private var nodes: [String: Node] = [:]
        private var statusNodes: [String: StatusNode] = [:]
        private var roots: [KeepsNavigationDirectory] = []
        private var children: [String: [KeepsNavigationDirectory]] = [:]
        private var errors: [String: String] = [:]
        private var loading: Set<String> = []
        private var generation = -1
        private var galleryLoadingPath: String?
        private var galleryPath: String?
        private var pendingGallerySelection = false
        private var hiddenPaths: Set<String> = []
        private var updating = false

        init(library: LibraryStore) { self.library = library }

        private func node(_ path: String) -> Node {
            if let existing = nodes[path] { return existing }
            let created = Node(path); nodes[path] = created; return created
        }
        private func status(_ path: String) -> StatusNode {
            if let existing = statusNodes[path] { return existing }
            let created = StatusNode(path); statusNodes[path] = created; return created
        }
        private func directory(_ path: String) -> KeepsNavigationDirectory? {
            roots.first { $0.path == path } ?? children.values.lazy.flatMap { $0 }.first { $0.path == path }
        }

        func update() {
            guard let outline, !updating else { return }
            updating = true
            defer { updating = false }
            let hiddenChanged = hiddenPaths != library.hiddenDirectoryPaths
            hiddenPaths = library.hiddenDirectoryPaths
            let oldRoots = roots
            let oldChildren = children
            let oldErrors = errors
            let oldLoading = loading
            let oldGalleryLoadingPath = galleryLoadingPath
            galleryLoadingPath = library.isLoading && !library.isCheckingRevision ? library.query.directory : nil
            let reset = generation != library.navigationGeneration
            roots = library.directories
            children = library.directoryChildren
            errors = library.directoryErrors
            loading = library.loadingDirectories
            generation = library.navigationGeneration
            let origin = outline.enclosingScrollView?.contentView.bounds.origin
            if reset {
                nodes = [:]; statusNodes = [:]
                outline.reloadData()
            } else if oldRoots.map(\.path) != roots.map(\.path) {
                let difference = roots.map(\.path).difference(from: oldRoots.map(\.path))
                outline.beginUpdates()
                for change in difference {
                    switch change {
                    case .remove(let index, _, _): outline.removeItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
                    case .insert(let index, _, _): outline.insertItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
                    }
                }
                outline.endUpdates()
            }
            let changed = Set(oldChildren.keys).union(children.keys).union(oldErrors.keys).union(errors.keys).union(oldLoading).union(loading)
            for path in changed where oldChildren[path] != children[path] || oldErrors[path] != errors[path] || oldLoading.contains(path) != loading.contains(path) {
                if let item = nodes[path], outline.row(forItem: item) >= 0 { outline.reloadItem(item, reloadChildren: true) }
            }
            for path in Set([oldGalleryLoadingPath, galleryLoadingPath].compactMap { $0 }) where oldGalleryLoadingPath != galleryLoadingPath {
                if let item = nodes[path] { outline.reloadItem(item) }
            }
            for root in roots where oldRoots.first(where: { $0.path == root.path }) != root {
                if let item = nodes[root.path] { outline.reloadItem(item) }
            }
            for path in library.expandedPaths.sorted(by: { $0.count < $1.count }) {
                let item = node(path)
                if outline.row(forItem: item) >= 0, !outline.isItemExpanded(item) { outline.expandItem(item) }
            }
            if reset || galleryPath != library.query.directory { pendingGallerySelection = true }
            if pendingGallerySelection {
                if let path = library.query.directory, let item = nodes[path], outline.row(forItem: item) >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false)
                    pendingGallerySelection = false
                } else {
                    outline.deselectAll(nil)
                    if library.query.directory == nil { pendingGallerySelection = false }
                }
            }
            galleryPath = library.query.directory
            if !reset, let origin, let scroll = outline.enclosingScrollView {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if hiddenChanged {
                for row in 0..<outline.numberOfRows {
                    if let item = outline.item(atRow: row) { outline.reloadItem(item) }
                }
            }
            let valid = Set(roots.map(\.path) + children.values.flatMap { $0.map(\.path) })
            nodes = nodes.filter { valid.contains($0.key) }
            statusNodes = statusNodes.filter { valid.contains($0.key) }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard !library.isOperationBlocking, outlineView.selectedRowIndexes.count <= 1,
                  let node = item as? Node,
                  !roots.contains(where: { $0.path == node.path }) else { return nil }
            dragGeneration = library.navigationGeneration
            let value = NSPasteboardItem()
            value.setString(node.path, forType: Self.directoryDragType)
            return value
        }

        private func draggedPath(_ info: NSDraggingInfo, target: Any?) -> (String, String)? {
            guard let source = info.draggingSource as? NSOutlineView, source === outline,
                  dragGeneration == library.navigationGeneration,
                  info.draggingPasteboard.pasteboardItems?.count == 1,
                  let target = target as? Node,
                  let path = info.draggingPasteboard.string(forType: Self.directoryDragType),
                  library.canMoveDirectory(path, to: target.path) else { return nil }
            return (path, target.path)
        }

        private func draggedPhotos(_ info: NSDraggingInfo, target: Any?) -> (PhotoDragPayload, String)? {
            guard let target = target as? Node,
                  let data = info.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(PhotoDragPayload.pasteboardType)),
                  let payload = try? JSONDecoder().decode(PhotoDragPayload.self, from: data),
                  library.canMovePhotos(payload, to: target.path) else { return nil }
            return (payload, target.path)
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let row = outlineView.row(at: outlineView.convert(info.draggingLocation, from: nil))
            guard row >= 0, let target = outlineView.item(atRow: row) as? Node,
                  draggedPhotos(info, target: target) != nil || draggedPath(info, target: target) != nil else {
                (outlineView as? DirectoryOutline)?.highlightDropTarget(row: -1)
                return []
            }
            (outlineView as? DirectoryOutline)?.highlightDropTarget(row: row)
            // 整行都表示移入该目录，避免行边缘被 AppKit 解释为插入相邻目录之间。
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard index == NSOutlineViewDropOnItemIndex else { return false }
            if let (payload, parent) = draggedPhotos(info, target: item) {
                Task { await library.movePhotos(payload, to: parent) }
                return true
            }
            guard let (path, parent) = draggedPath(info, target: item) else { return false }
            dragGeneration = nil
            Task { await library.moveDirectory(path, to: parent) }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item else { return roots.count }
            guard let item = item as? Node else { return 0 }
            return children[item.path].map { $0.count + (errors[item.path] == nil ? 0 : 1) } ?? 1
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item = item as? Node else { return node(roots[index].path) }
            if let values = children[item.path], index < values.count { return node(values[index].path) }
            return status(item.path)
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? Node else { return false }
            return children[item.path].map { !$0.isEmpty || errors[item.path] != nil } ?? (directory(item.path)?.hasChildren == true)
        }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !library.isOperationBlocking && item is Node }
        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool { !library.isOperationBlocking }
        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { !library.isOperationBlocking }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !updating, let item = notification.userInfo?["NSObject"] as? Node else { return }
            library.setDirectoryExpanded(item.path, expanded: true)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !updating, let item = notification.userInfo?["NSObject"] as? Node else { return }
            library.setDirectoryExpanded(item.path, expanded: false)
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline, outline.selectedRowIndexes.count == 1,
                  let item = outline.item(atRow: outline.selectedRow) as? Node else { return }
            if library.query.directory != item.path { library.showLibrary(directory: item.path) }
        }
        func contextMenu(for item: Any) -> NSMenu? {
            guard !library.isOperationBlocking, let node = item as? Node, let outline else { return nil }
            let menu = NSMenu()
            if outline.isExpandable(node) {
                let expanded = outline.isItemExpanded(node)
                let entry = menu.addItem(withTitle: expanded ? "折叠" : "展开", action: #selector(toggleDirectory(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = node
            }
            for (title, action) in [("刷新", #selector(refreshMetadata(_:))), ("复制服务器路径", #selector(copyDirectoryPath(_:)))] {
                let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                entry.target = self
                entry.representedObject = node
                if action == #selector(refreshMetadata(_:)) {
                    entry.isEnabled = library.client != nil && !library.submittingMetadataRefreshPaths.contains(node.path)
                }
            }
            menu.addItem(.separator())
            let explicitlyHidden = library.hiddenDirectoryPaths.contains(node.path)
            let entry = menu.addItem(withTitle: explicitlyHidden ? "取消隐藏目录" : "设为隐藏目录", action: #selector(toggleHiddenDirectory(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = node
            entry.isEnabled = !library.isUpdatingHiddenDirectory
            menu.autoenablesItems = false
            if library.isDirectoryHidden(node.path), !explicitlyHidden {
                let inherited = menu.addItem(withTitle: "已继承父目录的隐藏设置", action: nil, keyEquivalent: "")
                inherited.isEnabled = false
            }
            menu.addItem(.separator())
            let create = menu.addItem(withTitle: "添加文件夹…", action: #selector(createDirectory(_:)), keyEquivalent: "")
            create.target = self
            create.representedObject = node
            create.isEnabled = library.client != nil
            let rename = menu.addItem(withTitle: "重命名文件夹…", action: #selector(renameDirectory(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = node
            rename.isEnabled = library.canRenameDirectory(node.path)
            let trash = menu.addItem(withTitle: "删除文件夹…", action: #selector(trashDirectory(_:)), keyEquivalent: "")
            trash.target = self
            trash.representedObject = node
            return menu
        }

        @objc private func createDirectory(_ sender: NSMenuItem) {
            guard !library.isOperationBlocking, library.client != nil,
                  let node = sender.representedObject as? Node else { return }
            library.directoryToCreate = directory(node.path)
        }

        @objc private func renameDirectory(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? Node, library.canRenameDirectory(node.path) else { return }
            library.directoryToRename = directory(node.path)
        }

        @objc private func trashDirectory(_ sender: NSMenuItem) {
            guard !library.isOperationBlocking, let node = sender.representedObject as? Node else { return }
            library.directoryToTrash = directory(node.path)
        }

        @objc private func toggleHiddenDirectory(_ sender: NSMenuItem) {
            guard !library.isOperationBlocking, let node = sender.representedObject as? Node else { return }
            library.setDirectoryHidden(node.path, hidden: !library.hiddenDirectoryPaths.contains(node.path))
        }

        @objc private func toggleDirectory(_ sender: NSMenuItem) {
            guard !library.isOperationBlocking, let node = sender.representedObject as? Node, let outline else { return }
            if outline.isItemExpanded(node) { outline.collapseItem(node) }
            else { outline.expandItem(node) }
        }

        @objc private func refreshMetadata(_ sender: NSMenuItem) {
            guard !library.isDirectoryOperationBlocking, let node = sender.representedObject as? Node else { return }
            let store = library
            Task { @MainActor in
                if await store.refreshDirectoryMetadata(path: node.path) { openTaskWindow?() }
            }
        }

        @objc private func copyDirectoryPath(_ sender: NSMenuItem) {
            guard !library.isOperationBlocking, let node = sender.representedObject as? Node else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }

        @objc private func retry(_ sender: RetryButton) { library.loadChildren(of: sender.path, refresh: true) }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            if let item = item as? StatusNode {
                if let error = errors[item.parent] {
                    let button = RetryButton(title: "加载失败 · 重试", target: self, action: #selector(retry(_:)))
                    button.path = item.parent; button.isBordered = false; button.toolTip = error
                    return button
                }
                return NSTextField(labelWithString: "正在加载…")
            }
            guard let item = item as? Node, let directory = directory(item.path) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("directory-cell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? DirectoryCell ?? DirectoryCell(frame: .zero)
            cell.identifier = identifier
            cell.configure(directory, loading: loading.contains(item.path) || galleryLoadingPath == item.path, hidden: library.isDirectoryHidden(item.path))
            return cell
        }
    }
}

struct DirectoryCreateSheet: View {
    @ObservedObject var library: LibraryStore
    let directory: KeepsNavigationDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加文件夹").font(.headline)
            Text("父目录：\(directory.path)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("文件夹名称", text: $name).focused($nameFocused).disabled(isCreating)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isCreating)
                Button("创建") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isOperationBlocking)
            }
        }
        .padding(24).frame(width: 420)
        .interactiveDismissDisabled(isCreating)
        .onAppear { nameFocused = true }
    }

    @MainActor private func create() async {
        guard !isCreating, !library.isOperationBlocking, let client = library.client else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            _ = try await client.createDirectory(parentPath: directory.path,
                                                name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            library.loadChildren(of: directory.path, refresh: true)
            library.setDirectoryExpanded(directory.path, expanded: true)
            dismiss()
        } catch {
            self.error = String(reflecting: error) + "\n" + error.localizedDescription
        }
    }
}
