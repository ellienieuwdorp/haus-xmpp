import Photos
import UIKit

// One row of full-height squares on a phone; two rows once the rail is tall enough (iPad), filled column by column.
struct RecentPhotosRailGeometry: Equatable {
    static let spacing: CGFloat = 12
    let side: CGFloat
    let rows: Int
    let inset: CGFloat

    init(size: CGSize) {
        rows = size.height > 250 ? 2 : 1
        side = max(rows == 2 ? floor((size.height - Self.spacing) / 2) : size.height, 0)
        inset = size.width >= 430 ? 20 : 16
    }

    private var pitch: CGFloat { side + Self.spacing }

    func contentWidth(count: Int) -> CGFloat {
        let columns = (count + rows - 1) / rows
        return 2 * inset + CGFloat(columns) * side + CGFloat(max(columns - 1, 0)) * Self.spacing
    }

    func frame(of item: Int) -> CGRect {
        CGRect(x: inset + CGFloat(item / rows) * pitch, y: CGFloat(item % rows) * pitch, width: side, height: side)
    }

    // The items whose tiles overlap `minX..<maxX` in content coordinates.
    func items(from minX: CGFloat, to maxX: CGFloat, count: Int) -> Range<Int> {
        guard count > 0, side > 0, maxX > minX else { return 0..<0 }
        let first = max(Int(floor((minX - inset - side) / pitch)) + 1, 0)
        let last = Int(ceil((maxX - inset) / pitch)) - 1
        let lower = first * rows, upper = min((last + 1) * rows, count)
        return lower < upper ? lower..<upper : 0..<0
    }

    // Nil in the gaps between tiles and past the last one.
    func item(at point: CGPoint, count: Int) -> Int? {
        guard side > 0, point.x >= inset, point.y >= 0 else { return nil }
        let item = Int((point.x - inset) / pitch) * rows + (point.y >= pitch ? min(rows - 1, 1) : 0)
        return item < count && frame(of: item).contains(point) ? item : nil
    }
}

// No scroll view: one in the keyboard window takes the app window's bars into its scroll edge pockets, their rects
// convert to CGRectNull across the two windows' screens, and UIKit asserts on that. A windowless scroll view lends the
// rail its drag, deceleration and bounce through its pan recognizer; the rail recycles its tiles at that offset.
final class RecentPhotosRail: UIView, UIScrollViewDelegate {
    // Weak: UIKit keeps the last panel it showed after its chat is gone, and chip actions run a turn after the tap.
    private weak var keyboard: AttachmentKeyboard?
    private let scroller = UIScrollView()
    // Holds the tiles in content coordinates; its bounds origin follows the scroller's offset.
    private let content = UIView()
    private var backdrop: UIView?
    private let library = RecentPhotosLibrary.shared
    private var assets: PHFetchResult<PHAsset>?
    private var selection: [String] = []
    private var trayCount = 0
    private var loading: Set<String> = []
    private var geometry = RecentPhotosRailGeometry(size: .zero)
    private var tiles: [Int: RecentPhotoTile] = [:]
    private var spareTiles: [RecentPhotoTile] = []
    private var elements: [RecentPhotoElement] = []
    // A touch that stops the rail coasting selects nothing, as in a scroll view.
    private var touchStoppedScrolling = false
    var onAccessChanged: (Bool) -> Void = { _ in }

    private var count: Int { assets?.count ?? 0 }
    private var maxOffset: CGFloat { max(scroller.contentSize.width - scroller.bounds.width, 0) }

    init(keyboard: AttachmentKeyboard) {
        self.keyboard = keyboard
        super.init(frame: .zero)
        assets = library.assets
        library.attach(self)
        scroller.delegate = self
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.alwaysBounceHorizontal = true
        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        scroller.scrollsToTop = false
        addGestureRecognizer(scroller.panGestureRecognizer)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        // Tiles take no touches; the rail finds the tile under a tap, and a message's button stays reachable below.
        content.isUserInteractionEnabled = false
        content.clipsToBounds = true
        addSubview(content)
        accessibilityIdentifier = "recentPhotos"
        rebuildElements()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop?.frame = bounds
        let geometry = RecentPhotosRailGeometry(size: bounds.size)
        if geometry != self.geometry {
            self.geometry = geometry
            recycleTiles()
        }
        content.frame = CGRect(origin: .zero, size: bounds.size)
        // The scroller clamps its offset whenever its frame or content size is set, which would cut a drag's
        // stretch past either end short, so they are set only when they change.
        let frame = CGRect(origin: .zero, size: bounds.size)
        if scroller.frame != frame { scroller.frame = frame }
        let contentSize = CGSize(width: geometry.contentWidth(count: count), height: bounds.height)
        if scroller.contentSize != contentSize { scroller.contentSize = contentSize }
        if !scroller.isTracking, !scroller.isDecelerating {
            let x = min(max(scroller.contentOffset.x, 0), maxOffset)
            if x != scroller.contentOffset.x { scroller.contentOffset = CGPoint(x: x, y: 0) }
        }
        layoutTiles()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        content.bounds.origin = CGPoint(x: scrollView.contentOffset.x, y: 0)
        layoutTiles()
    }

    // Tiles within a tile's width of the visible part are made ahead, so they are ready as they come in.
    private func layoutTiles() {
        let x = scroller.contentOffset.x
        let wanted = geometry.items(from: x - geometry.side, to: x + bounds.width + geometry.side, count: count)
        for (item, tile) in tiles where !wanted.contains(item) {
            tiles[item] = nil
            recycle(tile)
        }
        for item in wanted where tiles[item] == nil {
            guard let asset = asset(at: item) else { continue }
            let tile = spareTiles.popLast() ?? makeTile()
            tile.frame = geometry.frame(of: item)
            tile.isHidden = false
            tile.show(asset: asset, manager: library.imageManager, side: geometry.side, scale: traitCollection.displayScale)
            configureState(tile, asset: asset)
            tiles[item] = tile
        }
    }

    private func makeTile() -> RecentPhotoTile {
        let tile = RecentPhotoTile()
        content.addSubview(tile)
        return tile
    }

    private func recycle(_ tile: RecentPhotoTile) {
        tile.prepareForReuse()
        tile.isHidden = true
        spareTiles.append(tile)
    }

    private func recycleTiles() {
        tiles.values.forEach(recycle)
        tiles = [:]
    }

    private func reloadTiles() {
        recycleTiles()
        rebuildElements()
        setNeedsLayout()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchStoppedScrolling = false
        // A bounce back past either end finishes on its own.
        if scroller.isDecelerating, (0...maxOffset).contains(scroller.contentOffset.x) {
            scroller.setContentOffset(scroller.contentOffset, animated: false)
            touchStoppedScrolling = true
        }
        super.touchesBegan(touches, with: event)
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard !touchStoppedScrolling, let item = geometry.item(at: tap.location(in: content), count: count) else { return }
        select(item)
    }

    private func setBackdrop(_ view: UIView?) {
        backdrop?.removeFromSuperview()
        backdrop = view
        guard let view else { return }
        view.frame = bounds
        insertSubview(view, at: 0)
    }

    func present() {
        RecentPhotosLibrary.panelOpened()
        alpha = 0
        UIView.animate(withDuration: 0.3) { self.alpha = 1 }
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            showAccessPrompt()
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reload() }
            }
        } else {
            reload()
        }
    }

    func reload() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        onAccessChanged(status == .limited)
        guard status == .authorized || status == .limited else {
            library.revoke()
            accessChanged()
            return
        }
        library.refresh(status)
        if let latest = library.assets, latest !== assets {
            show(latest, limited: status == .limited)
        } else {
            setBackdrop(assets == nil ? nil : emptyMessage())
        }
    }

    func show(_ latest: PHFetchResult<PHAsset>, limited: Bool) {
        onAccessChanged(limited)
        assets = latest
        reloadTiles()
        setBackdrop(emptyMessage())
        // Lays out the whole panel before making tiles, so they are made at their presented size; outside a window,
        // row constraint changes do not mark the panel for layout.
        if window == nil {
            superview?.setNeedsLayout()
            superview?.layoutIfNeeded()
            layoutIfNeeded()
        }
    }

    func accessChanged() {
        onAccessChanged(false)
        assets = nil
        reloadTiles()
        showAccessPrompt()
    }

    private func emptyMessage() -> UIView? {
        count == 0 ? message("No recent photos", button: nil) : nil
    }

    func update(selection: [String], trayCount: Int) {
        let changed = selection != self.selection
        self.selection = selection
        self.trayCount = trayCount
        loading.subtract(selection)
        if changed { refreshTiles() }
    }

    private func refreshTiles() {
        for (item, tile) in tiles {
            guard let asset = asset(at: item) else { continue }
            configureState(tile, asset: asset)
        }
    }

    private func showAccessPrompt() {
        let denied = PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined
        setBackdrop(message("Allow photo access to pick from your recent photos.", button: denied ? "Open Settings" : "Allow Access") { [weak self] in
            if denied { self?.keyboard?.openSettings() } else {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in Task { @MainActor [weak self] in self?.reload() } }
            }
        })
    }

    private func message(_ text: String, button title: String?, action: @escaping () -> Void = {}) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        if let title {
            var configuration = UIButton.Configuration.glass()
            configuration.title = title
            configuration.cornerStyle = .capsule
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.tintColor = .label
            button.accessibilityIdentifier = "allowPhotoAccess"
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
        ])
        return container
    }

    // Until the next layout pass after a reload, tiles and elements can hold items past a smaller read, and
    // `object(at:)` raises for those.
    private func asset(at item: Int) -> PHAsset? {
        guard let assets, item < assets.count else { return nil }
        return assets.object(at: item)
    }

    private func position(of asset: PHAsset) -> Int? {
        selection.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
    }

    private func configureState(_ tile: RecentPhotoTile, asset: PHAsset) {
        tile.setState(selected: position(of: asset), loading: loading.contains(asset.localIdentifier),
                      compact: traitCollection.verticalSizeClass == .compact)
    }

    @discardableResult func select(_ item: Int) -> Bool {
        guard let keyboard, let asset = asset(at: item) else { return false }
        let id = asset.localIdentifier
        if selection.contains(id) { keyboard.deselect(id); return true }
        guard !loading.contains(id) else { return true }
        guard trayCount + loading.count < ComposerPlan.trayLimit else {
            keyboard.refuse("You can attach up to \(ComposerPlan.trayLimit) files at a time.")
            return true
        }
        loading.insert(id)
        refreshTiles()
        Task { [weak self, keyboard] in
            await keyboard.select(asset)
            // Refused picks (too large, unreadable) never reach the selection; stop their spinner here.
            self?.loading.remove(id)
            self?.refreshTiles()
        }
        return true
    }

    // VoiceOver reaches every photo, not only the tiles on screen: each has an element, placed where its tile is.
    private func rebuildElements() {
        if elements.count > count { elements.removeLast(elements.count - count) }
        while elements.count < count { elements.append(RecentPhotoElement(item: elements.count, rail: self)) }
    }

    override var accessibilityElements: [Any]? {
        get { (backdrop.map { [$0] } ?? []) + elements }
        set {}
    }

    func accessibilityFrame(of item: Int) -> CGRect {
        UIAccessibility.convertToScreenCoordinates(content.convert(geometry.frame(of: item), to: self), in: self)
    }

    func accessibilityLabel(of item: Int) -> String? {
        asset(at: item).map { RecentPhotoTile.describe($0).label }
    }

    func accessibilityValue(of item: Int) -> String? {
        guard let asset = asset(at: item) else { return nil }
        return position(of: asset).map { "Selected, \($0) of \(selection.count)" } ?? (loading.contains(asset.localIdentifier) ? "Adding" : nil)
    }

    func accessibilityTraits(of item: Int) -> UIAccessibilityTraits {
        guard let asset = asset(at: item), position(of: asset) != nil else { return [.image, .button] }
        return [.image, .button, .selected]
    }

    // Brings a focused photo fully on screen, as a scroll view does for its focused cell.
    func reveal(_ item: Int) {
        let frame = geometry.frame(of: item)
        let x = scroller.contentOffset.x
        let target: CGFloat
        if frame.minX - geometry.inset < x {
            target = frame.minX - geometry.inset
        } else if frame.maxX + geometry.inset > x + bounds.width {
            target = frame.maxX + geometry.inset - bounds.width
        } else {
            return
        }
        scroller.setContentOffset(CGPoint(x: min(max(target, 0), maxOffset), y: 0), animated: false)
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let page = bounds.width
        guard page > 0 else { return false }
        let x = scroller.contentOffset.x
        let target: CGFloat
        switch direction {
        case .left, .next: target = min(x + page, maxOffset)
        case .right, .previous: target = max(x - page, 0)
        default: return false
        }
        guard abs(target - x) >= 1 else { return false }
        scroller.setContentOffset(CGPoint(x: target, y: 0), animated: false)
        let pages = max(Int((scroller.contentSize.width / page).rounded(.up)), 1)
        let current = target >= maxOffset - 1 ? pages : min(Int(target / page) + 1, pages)
        UIAccessibility.post(notification: .pageScrolled, argument: "Page \(current) of \(pages)")
        return true
    }
}

private final class RecentPhotoElement: UIAccessibilityElement {
    private let item: Int
    private weak var rail: RecentPhotosRail?

    init(item: Int, rail: RecentPhotosRail) {
        self.item = item
        self.rail = rail
        super.init(accessibilityContainer: rail)
        accessibilityIdentifier = "recentPhoto-\(item)"
    }

    override var accessibilityFrame: CGRect {
        get { rail?.accessibilityFrame(of: item) ?? .zero }
        set {}
    }

    override var accessibilityLabel: String? {
        get { rail?.accessibilityLabel(of: item) }
        set {}
    }

    override var accessibilityValue: String? {
        get { rail?.accessibilityValue(of: item) }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { rail?.accessibilityTraits(of: item) ?? [.image, .button] }
        set {}
    }

    override func accessibilityActivate() -> Bool { rail?.select(item) ?? false }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        rail?.reveal(item)
    }
}
