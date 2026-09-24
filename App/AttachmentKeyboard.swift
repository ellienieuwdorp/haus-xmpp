import AVFoundation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// A photo or a video just taken with the Camera chip.
enum CameraCapture {
    case image(Data)
    case movie(URL)
}

/// What the panel hands back to the conversation. The composer builds it on every open, so it always captures the
/// chat that is on screen.
struct AttachmentPanelActions {
    /// Prepares a recent photo into the tray; returns once it landed there or was refused.
    var select: (PHAsset) async -> Void
    /// Takes a recent photo back out of the tray.
    var deselect: (String) -> Void
    var capture: (CameraCapture) -> Void
    var photos: () -> Void
    var files: () -> Void
    /// A reason shown to the user: the tray is full, the camera is not allowed.
    var refuse: (String) -> Void
    /// The panel went away without the composer asking: the text field took over, a drag, the message menu.
    var dismissed: () -> Void
    /// The message menu closed without an action; the panel was up before it opened.
    var restore: () -> Void
}

/// The last docked system keyboard height per window size and orientation, so the panel replaces the keyboard
/// without a jump. Floating and hardware keyboards report small heights and are ignored.
enum KeyboardHeightCache {
    private static let prefix = "attachmentKeyboard.height."

    @MainActor private static func key(for window: UIWindow) -> String {
        let size = window.bounds.size
        return prefix + "\(Int(size.width))x\(Int(size.height))|" + (window.traitCollection.verticalSizeClass == .compact ? "compact" : "regular")
    }

    @MainActor static func record(_ height: CGFloat, in window: UIWindow) {
        guard height > 170 else { return }
        UserDefaults.standard.set(Double(height), forKey: key(for: window))
    }

    /// Fallbacks measured on iOS 26 with the predictive bar; the frame includes the home indicator area.
    @MainActor static func height(in window: UIWindow) -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: key(for: window))
        if stored > 170 { return stored }
        let size = window.bounds.size
        let landscape = size.width > size.height
        if window.traitCollection.userInterfaceIdiom == .pad { return landscape ? 422 : 337 }
        if landscape || window.traitCollection.verticalSizeClass == .compact { return 208 }
        if size.height >= 926 { return 345 }
        if size.height <= 667 { return 260 }
        return 335
    }
}

/// An invisible view whose input view is the attachment panel. UIKit then treats the panel as the keyboard: it
/// slides with the keyboard curve, the keyboard layout guide follows it, and a drag on the timeline dismisses it.
final class AttachmentKeyboardResponder: UIView {
    var panel: UIView?
    var onResign: () -> Void = {}
    var onBecome: () -> Void = {}
    var onStyleChange: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        // Rotating with the panel up leaves the keyboard guide measuring the old size (Signal dismisses here too).
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (responder: AttachmentKeyboardResponder, _) in
            if responder.isFirstResponder { _ = responder.resignFirstResponder() }
        }
        // The keyboard backdrop behind a live input view keeps the appearance it was presented in.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (responder: AttachmentKeyboardResponder, _) in
            if responder.isFirstResponder { responder.onStyleChange() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { panel }

    /// UIKit also makes the responder first again on its own, when a sheet presented over it goes away (the
    /// limited-library picker); the composer has to hear about that as much as about a resign.
    override func becomeFirstResponder() -> Bool {
        let wasFirst = isFirstResponder
        let became = super.becomeFirstResponder()
        if !wasFirst, became { onBecome() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let wasFirst = isFirstResponder
        let resigned = super.resignFirstResponder()
        if wasFirst, resigned { onResign() }
        return resigned
    }
}

/// Opens and closes the attachment panel for one conversation. The timeline controller installs its responder, so
/// the composer, the message insets and the message menu follow the panel exactly as they follow the keyboard.
@MainActor final class AttachmentKeyboard: NSObject {
    private let responder = AttachmentKeyboardResponder(frame: .zero)
    private(set) weak var host: UIViewController?
    private var panel: AttachmentKeyboardView?
    private var actions: AttachmentPanelActions?
    private var restoresAfterMenu = false
    private let camera = CameraDelegate()

    var isPresented: Bool { responder.isFirstResponder }

    override init() {
        super.init()
        responder.onResign = { [weak self] in
            guard let self, !replacing else { return }
            actions?.dismissed()
        }
        // The "+" and the send/search/chat-change closes all read the composer's state, so it must follow the
        // responder both ways; a resign for a presented picker is otherwise never undone when UIKit restores it.
        responder.onBecome = { [weak self] in
            guard let self, !replacing else { return }
            actions?.restore()
        }
        responder.onStyleChange = { [weak self] in self?.representPanel() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidChangeFrame(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// An interactive drag hides the panel but leaves its responder first (measured on iOS 26.5); resigning it
    /// here is what turns the × back into a +.
    @objc private func keyboardWillHide(_ note: Notification) {
        if isPresented { _ = responder.resignFirstResponder() }
    }

    func install(in controller: UIViewController) {
        host = controller
        controller.view.addSubview(responder)
    }

    func uninstall() {
        close()
        responder.removeFromSuperview()
        host = nil
    }

    func open(actions: AttachmentPanelActions, selection: [String], trayCount: Int) {
        self.actions = actions
        guard !isPresented else { update(selection: selection, trayCount: trayCount); return }
        guard let window = host?.view.window else { actions.dismissed(); return }
        let panel = self.panel ?? AttachmentKeyboardView(keyboard: self)
        self.panel = panel
        responder.panel = panel
        panel.prepare(height: KeyboardHeightCache.height(in: window), compact: window.traitCollection.verticalSizeClass == .compact)
        update(selection: selection, trayCount: trayCount)
        if !responder.becomeFirstResponder() { actions.dismissed() }
    }

    private var replacing = false

    /// The keyboard host resolves a live input view's backdrop once, when it is presented, so an appearance change
    /// presents the panel again in place, without animation and without telling the composer it closed.
    private func representPanel() {
        replacing = true
        UIView.performWithoutAnimation {
            _ = responder.resignFirstResponder()
            _ = responder.becomeFirstResponder()
        }
        replacing = false
    }

    func close() {
        if isPresented { _ = responder.resignFirstResponder() }
    }

    func update(selection: [String], trayCount: Int) {
        panel?.update(selection: selection, trayCount: trayCount)
    }

    /// Before the message menu puts the keyboard away.
    func menuWillPresent() { restoresAfterMenu = isPresented }

    /// True when the panel comes back, so the composer's own focus restore stays out of it.
    func menuDismissed(choseAction: Bool) -> Bool {
        defer { restoresAfterMenu = false }
        guard restoresAfterMenu, !choseAction, let actions else { return false }
        actions.restore()
        return true
    }

    // MARK: Panel callbacks

    func select(_ asset: PHAsset) async { await actions?.select(asset) }
    func deselect(_ id: String) { actions?.deselect(id) }
    func refuse(_ reason: String) { actions?.refuse(reason) }

    /// Signal's order: the panel goes first, then the full-screen picker comes up over a settled screen.
    func pickPhotos() {
        close()
        actions?.photos()
    }

    func pickFiles() {
        close()
        actions?.files()
    }

    func takePhoto() {
        close()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: presentCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    if granted { self?.presentCamera() } else { self?.refuse("Allow camera access in Settings to take a photo.") }
                }
            }
        default: refuse("Allow camera access in Settings to take a photo.")
        }
    }

    private func presentCamera() {
        guard let host, host.presentedViewController == nil, UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = camera
        camera.onCapture = { [weak self] capture in self?.actions?.capture(capture) }
        host.present(picker, animated: true)
    }

    func presentLimitedPicker() {
        guard let host else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: host)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func keyboardDidChangeFrame(_ note: Notification) {
        guard !isPresented, let window = host?.view.window,
              let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let local = window.convert(frame, from: window.screen.coordinateSpace)
        // Only a keyboard fully shown and docked at the bottom edge is a height the panel should copy: a floating
        // keyboard ends above it, and one part-way through a drag or a hide ends below it.
        guard abs(local.maxY - window.bounds.maxY) <= 1 else { return }
        KeyboardHeightCache.record(local.height, in: window)
    }
}

private final class CameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var onCapture: (CameraCapture) -> Void = { _ in }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        if let url = info[.mediaURL] as? URL {
            // The picker deletes its file once it closes; keep a copy for the export.
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { onCapture(.movie(copy)) }
        } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
            onCapture(.image(data))
        }
        picker.dismiss(animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
}

// MARK: - Panel

/// Replaces the software keyboard: an optional limited-access row, the recent photos rail and the format chips.
final class AttachmentKeyboardView: UIInputView {
    private unowned let keyboard: AttachmentKeyboard
    private let limitedRow = LimitedAccessRow()
    private let rail: RecentPhotosRail
    private let chips: FormatChipRow
    private var height: NSLayoutConstraint!
    private var top: NSLayoutConstraint!
    private var afterBanner: NSLayoutConstraint!
    private var chipHeight: NSLayoutConstraint!
    private var compact = false

    init(keyboard: AttachmentKeyboard) {
        self.keyboard = keyboard
        rail = RecentPhotosRail(keyboard: keyboard)
        chips = FormatChipRow(keyboard: keyboard)
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 335), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        // iOS 26 draws the keyboard backdrop behind an input view; the panel adds nothing of its own.
        backgroundColor = .clear
        accessibilityIdentifier = "attachmentPanel"
        limitedRow.onSelectMore = { [unowned keyboard] in keyboard.presentLimitedPicker() }
        limitedRow.onSettings = { [unowned keyboard] in keyboard.openSettings() }
        rail.onAccessChanged = { [weak self] limited in self?.showLimitedRow(limited) }
        for part in [limitedRow, rail, chips] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        height = heightAnchor.constraint(equalToConstant: 335)
        top = limitedRow.topAnchor.constraint(equalTo: topAnchor, constant: 36)
        afterBanner = rail.topAnchor.constraint(equalTo: limitedRow.bottomAnchor)
        chipHeight = chips.heightAnchor.constraint(equalToConstant: 122)
        limitedRow.isHidden = true
        limitedRow.collapsed = true
        NSLayoutConstraint.activate([
            height, top, afterBanner, chipHeight,
            limitedRow.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            limitedRow.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            rail.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            chips.topAnchor.constraint(equalTo: rail.bottomAnchor),
            chips.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            chips.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare(height value: CGFloat, compact: Bool) {
        height.constant = value
        self.compact = compact
        chips.compact = compact
        applyMetrics()
    }

    func update(selection: [String], trayCount: Int) {
        rail.update(selection: selection, trayCount: trayCount)
    }

    private func showLimitedRow(_ limited: Bool) {
        guard limitedRow.isHidden == limited else { return }
        limitedRow.isHidden = !limited
        applyMetrics()
    }

    /// Signal's iOS 26 measurements: 36pt above the rail (20 landscape), 17 above the limited-access row with 16
    /// after it, and a chip row of 122pt that gives up 22pt to the row.
    private func applyMetrics() {
        let banner = !limitedRow.isHidden
        top.constant = banner ? 17 : (compact ? 20 : 36)
        afterBanner.constant = banner ? 16 : 0
        chipHeight.constant = compact ? (banner ? 76 : 86) : (banner ? 100 : 122)
        // A hidden row still takes part in layout; collapse it so the rail starts at the top margin.
        limitedRow.collapsed = !banner
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        rail.present()
        chips.animateIn()
        UIAccessibility.post(notification: .layoutChanged, argument: rail)
    }
}

/// "You've given access to a selection of photos" plus a Manage menu.
private final class LimitedAccessRow: UIView {
    var onSelectMore: () -> Void = {}
    var onSettings: () -> Void = {}
    private var collapse: NSLayoutConstraint!
    private weak var manage: UIButton?
    var collapsed = false { didSet { collapse.isActive = collapsed } }

    /// Manage stays a small capsule beside one line of footnote text, but takes touches 44pt tall: the row, and
    /// the button through it, answer 8pt above and below their drawn bounds (the rail starts 16pt below).
    private static let reach: CGFloat = 8

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !collapsed && bounds.insetBy(dx: 0, dy: -Self.reach).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, self.point(inside: point, with: event) else { return nil }
        if let manage, manage.convert(manage.bounds, to: self).insetBy(dx: 0, dy: -Self.reach).contains(point) { return manage }
        return super.hitTest(point, with: event)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let label = UILabel()
        label.text = "You've given access to a selection of photos."
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        var configuration = UIButton.Configuration.glass()
        configuration.title = "Manage"
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        let manage = UIButton(configuration: configuration)
        self.manage = manage
        manage.tintColor = .label
        manage.showsMenuAsPrimaryAction = true
        manage.accessibilityIdentifier = "managePhotoAccess"
        manage.menu = UIMenu(children: [
            UIAction(title: "Select More Photos…", image: UIImage(systemName: "photo.badge.plus")) { [weak self] _ in self?.onSelectMore() },
            UIAction(title: "Change Settings", image: UIImage(systemName: "gear")) { [weak self] _ in self?.onSettings() },
        ])
        manage.setContentHuggingPriority(.required, for: .horizontal)
        manage.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, manage])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        collapse = heightAnchor.constraint(equalToConstant: 0)
        let fill = row.bottomAnchor.constraint(equalTo: bottomAnchor)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Recent photos

/// Up to 96 of the newest photos and videos, square tiles in one sideways row. Tapping adds to the tray in tap
/// order; tapping a selected tile takes it back out.
private final class RecentPhotosRail: UIView, UICollectionViewDataSource, UICollectionViewDelegate, PHPhotoLibraryChangeObserver {
    private unowned let keyboard: AttachmentKeyboard
    private let layout = UICollectionViewFlowLayout()
    private let collection: UICollectionView
    private let imageManager = PHCachingImageManager()
    private var assets: PHFetchResult<PHAsset>?
    private var selection: [String] = []
    private var trayCount = 0
    private var loading: Set<String> = []
    private var observing = false
    private var itemSide: CGFloat = 0
    var onAccessChanged: (Bool) -> Void = { _ in }

    init(keyboard: AttachmentKeyboard) {
        self.keyboard = keyboard
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 12
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.alwaysBounceHorizontal = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(RecentPhotoCell.self, forCellWithReuseIdentifier: "photo")
        collection.accessibilityIdentifier = "recentPhotos"
        collection.frame = bounds
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(collection)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        guard height > 0 else { return }
        // Two rows only once the rail is tall enough (iPad); a phone keeps one row of full-height squares.
        let side = height > 250 ? floor((height - 12) / 2) : height
        let inset: CGFloat = bounds.width >= 430 ? 20 : 16
        if abs(side - itemSide) > 0.5 || layout.sectionInset.left != inset {
            itemSide = side
            layout.itemSize = CGSize(width: side, height: side)
            layout.sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            layout.invalidateLayout()
            collection.reloadData()
        }
    }

    /// Asked for on first open only, never at launch.
    func present() {
        alpha = 0
        UIView.animate(withDuration: 0.3) { self.alpha = 1 }
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            showAccessPrompt()
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
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
            assets = nil
            collection.reloadData()
            showAccessPrompt()
            return
        }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.fetchLimit = 96
        if let library = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject {
            assets = PHAsset.fetchAssets(in: library, options: options)
        } else {
            assets = PHAsset.fetchAssets(with: options)
        }
        collection.reloadData()
        collection.backgroundView = (assets?.count ?? 0) == 0 ? message("No recent photos", button: nil) : nil
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.reload() }
    }

    func update(selection: [String], trayCount: Int) {
        let changed = selection != self.selection
        self.selection = selection
        self.trayCount = trayCount
        // Landed picks stop spinning; the badges renumber from the tray order.
        loading.subtract(selection)
        if changed { refreshVisibleCells() }
    }

    private func refreshVisibleCells() {
        for case let cell as RecentPhotoCell in collection.visibleCells {
            guard let path = collection.indexPath(for: cell), let asset = assets?.object(at: path.item) else { continue }
            configureState(cell, asset: asset, index: path.item)
        }
    }

    private func showAccessPrompt() {
        let denied = PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined
        collection.backgroundView = message("Allow photo access to pick from your recent photos.", button: denied ? "Open Settings" : "Allow Access") { [weak self] in
            if denied { self?.keyboard.openSettings() } else {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in Task { @MainActor [weak self] in self?.reload() } }
            }
        }
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

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { assets?.count ?? 0 }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! RecentPhotoCell
        guard let asset = assets?.object(at: indexPath.item) else { return cell }
        cell.show(asset: asset, manager: imageManager, side: itemSide, scale: traitCollection.displayScale)
        configureState(cell, asset: asset, index: indexPath.item)
        return cell
    }

    private func configureState(_ cell: RecentPhotoCell, asset: PHAsset, index: Int) {
        let id = asset.localIdentifier
        let position = selection.firstIndex(of: id).map { $0 + 1 }
        cell.setState(position: position, of: selection.count, loading: loading.contains(id), compact: traitCollection.verticalSizeClass == .compact)
        cell.accessibilityIdentifier = "recentPhoto-\(index)"
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let asset = assets?.object(at: indexPath.item) else { return }
        let id = asset.localIdentifier
        if selection.contains(id) { keyboard.deselect(id); return }
        guard !loading.contains(id) else { return }
        guard trayCount + loading.count < ComposerState.trayLimit else {
            keyboard.refuse("You can attach up to \(ComposerState.trayLimit) files at a time.")
            return
        }
        loading.insert(id)
        refreshVisibleCells()
        Task { [weak self, keyboard] in
            await keyboard.select(asset)
            // Refused picks (too large, unreadable) never reach the selection; stop their spinner here.
            self?.loading.remove(id)
            self?.refreshVisibleCells()
        }
    }
}

private final class RecentPhotoCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let durationLabel = UILabel()
    private let scrim = CAGradientLayer()
    private let dimming = UIView()
    private let badge = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var assetID: String?
    private var request: PHImageRequestID?
    private weak var manager: PHImageManager?
    private var baseLabel = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .tertiarySystemFill
        contentView.clipsToBounds = true
        contentView.cornerConfiguration = .uniformCorners(radius: .fixed(36))
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        // A dark corner under the duration keeps white text readable on any photo.
        scrim.type = .radial
        scrim.colors = [UIColor.black.withAlphaComponent(0.4).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        scrim.startPoint = CGPoint(x: 1, y: 1)
        scrim.endPoint = CGPoint(x: 0.35, y: 0.55)
        contentView.layer.addSublayer(scrim)
        durationLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        durationLabel.textColor = .white
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        dimming.frame = contentView.bounds
        dimming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(dimming)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)
        badge.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 13, weight: .bold))
        badge.textAlignment = .center
        badge.layer.cornerRadius = 12
        badge.layer.borderColor = UIColor.white.cgColor
        badge.layer.borderWidth = 1.5
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badge)
        NSLayoutConstraint.activate([
            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
            // Inset from the curve rather than the square corner, so the badge sits inside the rounded tile.
            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrim.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let request { manager?.cancelImageRequest(request) }
        request = nil
        imageView.image = nil
    }

    func show(asset: PHAsset, manager: PHCachingImageManager, side: CGFloat, scale: CGFloat) {
        assetID = asset.localIdentifier
        self.manager = manager
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let id = asset.localIdentifier
        let target = CGSize(width: max(side, 1) * scale, height: max(side, 1) * scale)
        request = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { [weak self] image, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.assetID == id else { return }
                    self.imageView.image = image
                }
            }
        }
        let isVideo = asset.mediaType == .video
        durationLabel.isHidden = !isVideo
        scrim.isHidden = !isVideo
        let seconds = Int(asset.duration.rounded())
        let duration = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        durationLabel.text = isVideo ? duration : nil
        let date = asset.creationDate?.formatted(date: .abbreviated, time: .shortened)
        baseLabel = ([isVideo ? "Video, \(duration)" : "Photo"] + [date].compactMap { $0 }).joined(separator: ", ")
    }

    func setState(position: Int?, of total: Int, loading: Bool, compact: Bool) {
        contentView.cornerConfiguration = .uniformCorners(radius: .fixed(compact ? 20 : 36))
        let selected = position != nil
        dimming.isHidden = !(selected || loading)
        badge.isHidden = !selected
        badge.text = position.map(String.init)
        badge.backgroundColor = AccentTheme.current.bubble
        badge.textColor = AccentTheme.current.bubbleText
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityLabel = baseLabel
        accessibilityTraits = selected ? [.image, .button, .selected] : [.image, .button]
        accessibilityValue = position.map { "Selected, \($0) of \(total)" } ?? (loading ? "Adding" : nil)
    }
}

// MARK: - Format chips

/// Camera, Photos and File as 76×50 glass capsules with a label underneath, springing in on every open.
private final class FormatChipRow: UIView {
    private let stack = UIStackView()
    private var items: [UIView] = []
    private var buttonHeights: [NSLayoutConstraint] = []
    var compact = false { didSet { buttonHeights.forEach { $0.constant = compact ? 40 : 50 } } }

    init(keyboard: AttachmentKeyboard) {
        super.init(frame: .zero)
        var chips: [(title: String, symbol: String, identifier: String, action: () -> Void)] = []
        // The simulator and some iPads have no camera; the chip is left out rather than shown dead.
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            chips.append(("Camera", "camera.fill", "attachCamera", { [unowned keyboard] in keyboard.takePhoto() }))
        }
        chips.append(("Photos", "photo.on.rectangle.angled", "attachPhotos", { [unowned keyboard] in keyboard.pickPhotos() }))
        chips.append(("File", "doc", "attachFiles", { [unowned keyboard] in keyboard.pickFiles() }))
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for chip in chips {
            stack.addArrangedSubview(item(title: chip.title, symbol: chip.symbol, identifier: chip.identifier, action: chip.action))
        }
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func item(title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> UIView {
        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium))
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            // One run loop later, so the pressed glass shows before the panel goes.
            DispatchQueue.main.async { action() }
        })
        button.tintColor = .label
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        button.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = title
        label.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .medium))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.isAccessibilityElement = false
        let column = UIStackView(arrangedSubviews: [button, label])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 8
        let buttonHeight = button.heightAnchor.constraint(equalToConstant: 50)
        buttonHeights.append(buttonHeight)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 76), buttonHeight])
        items.append(column)
        return column
    }

    /// Each chip springs from half size, a third of the duration after the one before it.
    func animateIn() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        for item in items {
            item.alpha = 0
            item.transform = reduceMotion ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
        }
        // Critically damped with a 0.2s response: stiffness (2π/0.2)², damping 4π/0.2.
        let spring = UISpringTimingParameters(mass: 1, stiffness: pow(2 * .pi / 0.2, 2), damping: 4 * .pi / 0.2, initialVelocity: .zero)
        let animator = UIViewPropertyAnimator(duration: 0.5, timingParameters: spring)
        for (index, item) in items.enumerated() {
            animator.addAnimations({
                item.alpha = 1
                item.transform = .identity
            }, delayFactor: reduceMotion ? 0 : CGFloat(index) / CGFloat(items.count))
        }
        animator.startAnimation()
    }
}
