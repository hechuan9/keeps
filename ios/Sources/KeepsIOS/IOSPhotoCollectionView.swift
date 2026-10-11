import SwiftUI
import UIKit
import KeepsAPI
import OSLog

struct IOSPhotoCollectionView: UIViewControllerRepresentable {
    let library: IOSLibraryStore
    @Binding var selecting: Bool
    @Binding var selectedIDs: Set<UUID>
    @Binding var density: KeepsGalleryDensity
    @Binding var visibleDates: String
    var style: KeepsGalleryStyle
    var preparationFinished: (String?) -> Void
    var open: (KeepsAsset) -> Void
    var information: (KeepsAsset) -> Void

    func makeUIViewController(context: Context) -> PhotoCollectionController { PhotoCollectionController() }

    func updateUIViewController(_ controller: PhotoCollectionController, context: Context) {
        controller.preparationFinished = preparationFinished
        controller.open = { id in
            Task {
                guard let asset = await library.asset(id: id), await library.restoreWindow(around: asset) else { return }
                open(asset)
            }
        }
        controller.information = { id in
            Task { if let asset = await library.asset(id: id) { information(asset) } }
        }
        controller.select = { id in selecting = true; selectedIDs.insert(id) }
        controller.toggleSelection = { id in
            if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
        }
        controller.changeDensity = { density = $0 }
        controller.changeDates = { if visibleDates != $0 { visibleDates = $0 } }
        controller.changeVisibleIDs = { library.visibleIDs = $0 }
        controller.update(entries: library.timeline, revision: library.timelineRevision,
                          configuration: library.configuration, density: density, style: style,
                          selecting: selecting, selected: selectedIDs)
    }

    static func dismantleUIViewController(_ controller: PhotoCollectionController, coordinator: ()) {
        controller.cancelRequests()
    }
}

/// The layout owns positions for the entire library, but only creates attributes near the viewport.
private final class TimelineCollectionLayout: UICollectionViewLayout {
    var geometry = KeepsTimelineGeometry(aspectRatios: [], width: 0, density: .large, style: .square)
    var anchorOffset: CGPoint?
    override var collectionViewContentSize: CGSize { geometry.contentSize }
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        anchorOffset ?? proposedContentOffset
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let frame = geometry.frame(at: indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame
        return attributes
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        geometry.indices(in: rect).compactMap { index in
            guard let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: 0)),
                  attributes.frame.intersects(rect) else { return nil }
            return attributes
        }
    }
}

final class PhotoCollectionController: UIViewController, UICollectionViewDelegate,
                                       UICollectionViewDataSource, UICollectionViewDataSourcePrefetching {
    var open: (UUID) -> Void = { _ in }
    var information: (UUID) -> Void = { _ in }
    var select: (UUID) -> Void = { _ in }
    var toggleSelection: (UUID) -> Void = { _ in }
    var changeDensity: (KeepsGalleryDensity) -> Void = { _ in }
    var changeDates: (String) -> Void = { _ in }
    var changeVisibleIDs: (Set<UUID>) -> Void = { _ in }
    var preparationFinished: (String?) -> Void = { _ in }

    private var collection: UICollectionView!
    private let layout = TimelineCollectionLayout()
    private var entries: [KeepsTimelineEntry] = []
    private var pending: [KeepsTimelineEntry] = []
    private var pendingRevision = -1
    private var appliedRevision = -1
    private var configuration: KeepsConfiguration?
    private var density = KeepsGalleryDensity.large
    private var appliedDensity: KeepsGalleryDensity?
    private var style = KeepsGalleryStyle.square
    private var appliedStyle: KeepsGalleryStyle?
    private var appliedWidth: CGFloat = 0
    private var selecting = false
    private var selected: Set<UUID> = []
    private var applying = false
    private var fastScrolling = false
    private var scrubbing = false
    private var dates = ""
    private var previousOffset: CGFloat = 0
    private var previousTime: CFTimeInterval = 0
    private var prefetches: [UUID: Task<Void, Never>] = [:]
    private var standardBufferTask: Task<Void, Never>?
    private var standardBufferKeys: [String] = []
    private let rail = TimelineRail()
    private let railTrack = UIView()
    private let railThumb = UIView()
    private let dateBubble = UILabel()
    private var railHideTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .black
        collection.alwaysBounceVertical = true
        collection.showsVerticalScrollIndicator = false
        collection.contentInsetAdjustmentBehavior = .never
        collection.contentInset.bottom = 90
        collection.delegate = self
        collection.dataSource = self
        collection.prefetchDataSource = self
        collection.accessibilityIdentifier = "photo-grid"
        collection.register(PhotoCollectionCell.self, forCellWithReuseIdentifier: "photo")
        view.addSubview(collection)
        collection.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        rail.accessibilityLabel = "按日期浏览照片"
        rail.accessibilityHint = "上下拖动可定位整个图库"
        rail.accessibilityIdentifier = "timeline-rail"
        rail.isAccessibilityElement = true
        rail.accessibilityTraits = .adjustable
        rail.alpha = 0
        rail.adjust = { [weak self] direction in
            guard let self else { return }
            collection.contentOffset.y = max(0, min(bottomOffset, collection.contentOffset.y + CGFloat(direction) * collection.bounds.height))
            finishScrolling()
        }
        rail.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(scrubbed(_:))))
        rail.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(jumped(_:))))
        railTrack.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        railTrack.layer.cornerRadius = 1
        railThumb.backgroundColor = .white
        railThumb.layer.cornerRadius = 3
        rail.addSubview(railTrack)
        rail.addSubview(railThumb)
        view.addSubview(rail)
        dateBubble.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        dateBubble.textColor = .white
        dateBubble.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        dateBubble.textAlignment = .center
        dateBubble.layer.cornerRadius = 8
        dateBubble.clipsToBounds = true
        dateBubble.isHidden = true
        view.addSubview(dateBubble)
    }

    func update(entries: [KeepsTimelineEntry], revision: Int, configuration: KeepsConfiguration?,
                density: KeepsGalleryDensity, style: KeepsGalleryStyle, selecting: Bool, selected: Set<UUID>) {
        loadViewIfNeeded()
        let appearanceChanged = self.selecting != selecting || self.selected != selected || self.configuration != configuration
        self.configuration = configuration
        self.density = density
        self.style = style
        self.selecting = selecting
        self.selected = selected
        if pendingRevision != revision {
            pending = entries
            pendingRevision = revision
        }
        if appearanceChanged { updateVisibleCells() }
        applyPending()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        collection.frame = view.bounds
        rail.frame = CGRect(x: view.bounds.width - 30, y: 65, width: 30, height: max(1, view.bounds.height - 175))
        railTrack.frame = CGRect(x: 20, y: 0, width: 2, height: rail.bounds.height)
        applyPending()
        updateDates()
        updateRail()
    }

    private func entry(at index: Int) -> KeepsTimelineEntry { entries[entries.count - 1 - index] }
    private var bottomOffset: CGFloat { max(0, layout.collectionViewContentSize.height + collection.contentInset.bottom - collection.bounds.height) }

    private func applyPending() {
        guard !applying, !collection.isTracking, !collection.isDecelerating, !scrubbing,
              collection.bounds.width > 0 else { return }
        let reflow = appliedWidth != collection.bounds.width || appliedDensity != density || appliedStyle != style
        guard reflow || appliedRevision != pendingRevision else { return }
        let path = collection.indexPathsForVisibleItems.sorted().first
        let anchor = path.flatMap { path -> (UUID, CGFloat)? in
            guard path.item < entries.count, let frame = layout.geometry.frame(at: path.item) else { return nil }
            return (entry(at: path.item).id, frame.minY - collection.contentOffset.y)
        }
        let initial = entries.isEmpty
        cancelPrefetches()
        entries = pending
        appliedRevision = pendingRevision
        appliedWidth = collection.bounds.width
        appliedDensity = density
        appliedStyle = style
        applying = true
        layout.geometry = KeepsTimelineGeometry(
            aspectRatios: entries.reversed().map { JustifiedAssetGridLayout.aspectRatio($0.gridPreview) },
            width: appliedWidth, density: density, style: style)
        let target: CGFloat
        if let anchor, let index = entries.firstIndex(where: { $0.id == anchor.0 }),
           let frame = layout.geometry.frame(at: entries.count - 1 - index) {
            target = max(0, min(bottomOffset, frame.minY - anchor.1))
        } else if initial {
            target = bottomOffset
        } else {
            target = max(0, min(collection.contentOffset.y, bottomOffset))
        }
        layout.anchorOffset = CGPoint(x: 0, y: target)
        UIView.performWithoutAnimation {
            collection.reloadData()
            layout.invalidateLayout()
            collection.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            collection.layoutIfNeeded()
        }
        layout.anchorOffset = nil
        applying = false
        updateDates()
        preparationFinished(nil)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! PhotoCollectionCell
        configure(cell, at: indexPath)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let cell = cell as? PhotoCollectionCell { configure(cell, at: indexPath) }
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? PhotoCollectionCell)?.cancelRequest()
    }
    private func configure(_ cell: PhotoCollectionCell, at path: IndexPath) {
        let entry = entry(at: path.item)
        cell.configure(entry: entry, configuration: configuration, compact: style == .square,
                       selecting: selecting, selected: selected.contains(entry.id),
                       scale: view.window?.screen.scale ?? 3, browsing: fastScrolling || scrubbing,
                       loadStandard: density == .single)
    }
    private func updateVisibleCells() {
        for path in collection.indexPathsForVisibleItems where path.item < entries.count {
            if let cell = collection.cellForItem(at: path) as? PhotoCollectionCell { configure(cell, at: path) }
        }
    }
    private func updateDates() {
        updateStandardBuffer()
        let visible = collection.indexPathsForVisibleItems.filter { $0.item < entries.count }.sorted()
        changeVisibleIDs(Set(visible.map { entry(at: $0.item).id }))
        guard let first = visible.first, let last = visible.last else { return }
        let start = String(entry(at: first.item).date.prefix(10))
        let end = String(entry(at: last.item).date.prefix(10))
        let next = start == end ? start : "\(start) – \(end)"
        dateBubble.text = String(entry(at: first.item).date.prefix(7))
        rail.accessibilityValue = next
        updateRail()
        guard dates != next else { return }
        dates = next
        Task { @MainActor [weak self] in
            guard let self, dates == next else { return }
            changeDates(next)
        }
    }
    private func updateStandardBuffer() {
        let visible = collection.indexPathsForVisibleItems.map(\.item).sorted()
        guard density == .single, !fastScrolling, !scrubbing, let configuration,
              let first = visible.first, let last = visible.last else {
            standardBufferTask?.cancel()
            standardBufferKeys = []
            return
        }
        let buffer = [last + 1, first - 1, last + 2, first - 2]
            .filter { entries.indices.contains($0) }.map { entry(at: $0) }
        let keys = buffer.map { "\($0.id):\($0.standard?.version ?? "")" }
        guard keys != standardBufferKeys else { return }
        standardBufferTask?.cancel()
        standardBufferKeys = keys
        standardBufferTask = Task(priority: .utility) {
            for entry in buffer {
                guard !Task.isCancelled else { return }
                guard let standard = entry.standard else { continue }
                do {
                    let cached = try await PreviewCache.standards.prefetch(assetID: entry.id, preview: standard,
                        configuration: configuration, skipWhenBusy: false)
                    if !cached { return }
                } catch {
                    guard !Task.isCancelled else { return }
                    Logger(subsystem: "com.hechuan.Keeps", category: "photo-grid")
                        .error("Standard prefetch failed: \(String(reflecting: error), privacy: .public)")
                }
            }
        }
    }
    private func updateRail() {
        rail.isHidden = bottomOffset <= 0
        let fraction = bottomOffset > 0 ? max(0, min(1, collection.contentOffset.y / bottomOffset)) : 1
        let y = fraction * max(0, rail.bounds.height - 28)
        railThumb.frame = CGRect(x: 18, y: y, width: 6, height: 28)
        dateBubble.frame = CGRect(x: rail.frame.minX - 104, y: rail.frame.minY + y - 4, width: 100, height: 36)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        showRail()
        previousOffset = scrollView.contentOffset.y
        previousTime = CACurrentMediaTime()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applying else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - previousTime
        if elapsed > 0, elapsed < 0.3, scrollView.isDragging || scrollView.isDecelerating {
            let speed = abs(scrollView.contentOffset.y - previousOffset) / elapsed
            setFastScrolling(speed > scrollView.bounds.height * 1.5)
        }
        previousOffset = scrollView.contentOffset.y
        previousTime = now
        updateDates()
        // UIKit may omit cancellation callbacks after a large jump; keep only nearby requests.
        let nearby = layout.geometry.indices(in: collection.bounds.insetBy(dx: 0, dy: -collection.bounds.height))
        let retained = Set(nearby.map { entry(at: $0).id })
        for id in Array(prefetches.keys) where !retained.contains(id) { prefetches.removeValue(forKey: id)?.cancel() }
    }
    private func setFastScrolling(_ fast: Bool) {
        guard fastScrolling != fast else { return }
        fastScrolling = fast
        updateVisibleCells()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishScrolling() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScrolling() }
    private func showRail() {
        railHideTask?.cancel()
        rail.layer.removeAllAnimations()
        rail.alpha = 1
    }
    private func hideRailAfterScrolling() {
        railHideTask?.cancel()
        railHideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            guard let self, !scrubbing, !collection.isDragging, !collection.isDecelerating else { return }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.rail.alpha = 0
            }
        }
    }
    private func finishScrolling() {
        setFastScrolling(false)
        applyPending()
        collection.layoutIfNeeded()
        updateDates()
        updateVisibleCells()
        hideRailAfterScrolling()
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let next = density.pinched(magnification: gesture.scale)
        if next != density { changeDensity(next) }
    }
    @objc private func scrubbed(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            showRail()
            collection.setContentOffset(collection.contentOffset, animated: false)
            scrubbing = true
            dateBubble.isHidden = false
            updateVisibleCells()
        }
        if gesture.state == .began || gesture.state == .changed { jump(to: gesture.location(in: rail).y) }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            scrubbing = false
            dateBubble.isHidden = true
            finishScrolling()
        }
    }
    @objc private func jumped(_ gesture: UITapGestureRecognizer) {
        showRail()
        jump(to: gesture.location(in: rail).y)
        finishScrolling()
    }
    private func jump(to y: CGFloat) {
        let fraction = max(0, min(1, y / max(1, rail.bounds.height)))
        collection.contentOffset.y = fraction * bottomOffset
        collection.layoutIfNeeded()
        updateDates()
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let id = entry(at: indexPath.item).id
        if selecting { toggleSelection(id) } else { open(id) }
    }
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        let id = entry(at: indexPath.item).id
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "查看照片", image: UIImage(systemName: "photo")) { _ in self?.open(id) },
                UIAction(title: "选择", image: UIImage(systemName: "checkmark.circle")) { _ in self?.select(id) },
                UIAction(title: "信息与整理", image: UIImage(systemName: "info.circle")) { _ in self?.information(id) }
            ])
        }
    }
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let configuration else { return }
        for path in indexPaths.prefix(120) where path.item < entries.count {
            let entry = entry(at: path.item)
            guard prefetches[entry.id] == nil, let preview = entry.browseThumbnail else { continue }
            prefetches[entry.id] = Task(priority: .utility) {
                do {
                    _ = try await PreviewCache.browsing
                        .image(assetID: entry.id, preview: preview, configuration: configuration, maxPixelSize: 64, allowDownload: false)
                } catch let error as URLError where error.code == .fileDoesNotExist {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    Logger(subsystem: "com.hechuan.Keeps", category: "photo-grid")
                        .error("Thumbnail prefetch failed: \(String(reflecting: error), privacy: .public)")
                }
            }
        }
    }
    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for path in indexPaths where path.item < entries.count {
            prefetches.removeValue(forKey: entry(at: path.item).id)?.cancel()
        }
    }
    private func cancelPrefetches() {
        standardBufferTask?.cancel()
        standardBufferKeys = []
        prefetches.values.forEach { $0.cancel() }
        prefetches.removeAll()
    }
    func cancelRequests() {
        cancelPrefetches()
        for case let cell as PhotoCollectionCell in collection.visibleCells { cell.cancelRequest() }
    }
}

private final class TimelineRail: UIView {
    var adjust: (Int) -> Void = { _ in }
    override func accessibilityIncrement() { adjust(1) }
    override func accessibilityDecrement() { adjust(-1) }
}

private final class PhotoCollectionCell: UICollectionViewCell {
    private let photo = UIImageView()
    private let badge = UIImageView()
    private let videoBadge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private var task: Task<Void, Never>?
    private var standardTask: Task<Void, Never>?
    private var key: String?
    private var entry: KeepsTimelineEntry?
    private var configuration: KeepsConfiguration?
    private var scale: CGFloat = 3
    private var browsing = false
    private var hasSharpImage = false
    private var hasBrowseImage = false
    private var hasStandardImage = false
    private var loadStandard = false
    private static let placeholder = UIImage(cgImage: KeepsThumbnailPlaceholder.image)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(red: 0.145, green: 0.149, blue: 0.157, alpha: 1)
        photo.image = Self.placeholder
        contentView.clipsToBounds = true
        photo.clipsToBounds = true
        photo.tintColor = .secondaryLabel
        contentView.addSubview(photo)
        badge.tintColor = .white
        badge.layer.shadowOpacity = 0.7
        badge.layer.shadowRadius = 2
        contentView.addSubview(badge)
        videoBadge.tintColor = .white
        videoBadge.layer.shadowOpacity = 0.8
        videoBadge.layer.shadowRadius = 4
        contentView.addSubview(videoBadge)
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest()
        entry = nil
        photo.image = Self.placeholder
        hasSharpImage = false
        hasBrowseImage = false
        hasStandardImage = false
    }
    func cancelRequest() {
        task?.cancel(); task = nil
        standardTask?.cancel(); standardTask = nil
        key = nil
    }
    func configure(entry: KeepsTimelineEntry, configuration: KeepsConfiguration?, compact: Bool,
                   selecting: Bool, selected: Bool, scale: CGFloat, browsing: Bool, loadStandard: Bool) {
        if self.entry?.id != entry.id || self.entry?.gridPreview?.version != entry.gridPreview?.version || self.entry?.standard?.version != entry.standard?.version || self.configuration != configuration || self.loadStandard != loadStandard {
            cancelRequest()
            photo.image = Self.placeholder
            hasSharpImage = false
            hasBrowseImage = false
            hasStandardImage = false
        } else if self.entry?.browseThumbnail?.version != entry.browseThumbnail?.version {
            hasBrowseImage = false
        }
        self.entry = entry
        self.configuration = configuration
        self.scale = scale
        self.browsing = browsing
        self.loadStandard = loadStandard
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "重新载入缩略图", target: self, selector: #selector(retryImage))]
        accessibilityLabel = entry.isVideo ? "视频：\(entry.filename)" : entry.filename
        videoBadge.isHidden = !entry.isVideo
        accessibilityTraits = selected ? [.button, .selected] : .button
        photo.contentMode = compact ? .scaleAspectFill : .scaleAspectFit
        let symbol = selecting ? (selected ? "checkmark.circle.fill" : "circle") : (entry.flagState == "picked" ? "heart.fill" : nil)
        badge.image = symbol.flatMap { UIImage(systemName: $0) }
        badge.tintColor = selected ? .systemCyan : .white
        badge.isHidden = symbol == nil
        loadImage()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        photo.frame = contentView.bounds
        badge.frame = CGRect(x: bounds.width - 25, y: bounds.height - 25, width: 21, height: 21)
        let size = min(44, max(24, bounds.height * 0.3))
        videoBadge.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        loadImage()
    }
    @objc private func retryImage() -> Bool { cancelRequest(); hasSharpImage = false; loadImage(); return true }
    private func loadImage() {
        guard let entry, let configuration, bounds.width > 0 else { return }
        guard entry.gridPreview != nil || entry.browseThumbnail != nil else {
            cancelRequest()
            photo.image = Self.placeholder
            accessibilityValue = "缩略图尚未生成"
            return
        }
        if browsing && hasSharpImage { return }
        let pixels = Int(ceil(max(bounds.width, bounds.height) * scale))
        let next = "\(entry.id):\(entry.gridPreview?.version ?? ""):\(entry.browseThumbnail?.version ?? ""):\(entry.standard?.version ?? ""):\(pixels):\(browsing):\(loadStandard)"
        guard key != next else { return }
        task?.cancel()
        standardTask?.cancel()
        key = next
        let lowOnly = browsing
        if loadStandard, !lowOnly, let standard = entry.standard {
            standardTask = Task { @MainActor [weak self] in
                do {
                    let image = try await PreviewCache.standards.image(assetID: entry.id, preview: standard,
                        configuration: configuration, maxPixelSize: pixels)
                    try Task.checkCancellation()
                    guard let self, key == next else { return }
                    photo.image = UIImage(cgImage: image)
                    hasStandardImage = true
                    hasSharpImage = true
                    accessibilityValue = nil
                } catch {
                    guard !Task.isCancelled, let self, key == next else { return }
                    report(error)
                }
            }
        }
        task = Task { @MainActor [weak self] in
            if self?.hasBrowseImage == false, self?.hasSharpImage == false, let preview = entry.browseThumbnail {
                do {
                    let small = try await PreviewCache.browsing.image(assetID: entry.id, preview: preview,
                        configuration: configuration, maxPixelSize: 64, allowDownload: !lowOnly)
                    try Task.checkCancellation()
                    guard let self, key == next, !hasStandardImage else { return }
                    photo.image = UIImage(cgImage: small)
                    hasBrowseImage = true
                    accessibilityValue = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    if (error as? URLError)?.code != .fileDoesNotExist { self?.report(error) }
                }
            }
            guard !Task.isCancelled, !lowOnly, let preview = entry.gridPreview else { return }
            do {
                let role: KeepsMediaRole = entry.thumbnail == nil ? .preview : .thumbnail
                let image = try await PreviewCache.cache(for: role).image(assetID: entry.id, preview: preview,
                    configuration: configuration, maxPixelSize: pixels)
                try Task.checkCancellation()
                guard let self, key == next, !hasStandardImage else { return }
                photo.image = UIImage(cgImage: image)
                hasSharpImage = true
                accessibilityValue = nil
            } catch {
                guard !Task.isCancelled, let self, key == next else { return }
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        accessibilityValue = String(reflecting: error)
        Logger(subsystem: "com.hechuan.Keeps", category: "photo-grid")
            .error("Thumbnail failed: \(String(reflecting: error), privacy: .public)")
    }
}
