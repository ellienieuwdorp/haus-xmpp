import AVFoundation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

enum CameraCapture {
    case image(Data)
    case movie(URL)
}

// Built by the composer on every open, so it always targets the chat on screen.
struct AttachmentPanelActions {
    // Looked up on each use: SwiftUI rebuilds the text view.
    var field: () -> UITextView?
    var select: (PHAsset) async -> Void
    var deselect: (String) -> Void
    var capture: (CameraCapture) -> Void
    var photos: () -> Void
    var files: () -> Void
    var refuse: (String) -> Void
    var dismissed: () -> Void
    var restore: () -> Void
}

// Floating and hardware keyboards report small heights and are not cached.
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

// The panel is the field's `inputView`, swapped with the letters by `reloadInputViews()` while the field stays
// first responder, so UIKit animates, tracks and dismisses it as the keyboard with one responder to restore.
@MainActor final class AttachmentKeyboard: NSObject {
    private(set) weak var host: UIViewController?
    private var panel: AttachmentKeyboardView?
    private var actions: AttachmentPanelActions?
    private weak var field: UITextView?
    // Put back when the letters return; they show above the keyboard on iPad.
    private var assistantGroups: (leading: [UIBarButtonItemGroup], trailing: [UIBarButtonItemGroup])?
    private lazy var fieldTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(fieldTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()
    // Set when the field ends editing on its own; the next turn tells a dismissal from SwiftUI replacing the field.
    private var movingToNewField = false
    private var closing = false
    // Presenting the picker takes the field's focus and UIKit returns it with the panel on close, so the panel stays
    // attached meanwhile. Detaching clears this, so a picker closing after the panel was put away restores nothing.
    private var pickingMore: UUID?
    private var restoresAfterMenu = false
    private var rotation: (any UITraitChangeRegistration)?
    private let camera = CameraDelegate()

    var isPresented: Bool {
        guard let field, let panel else { return false }
        return field.inputView === panel && field.isFirstResponder
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(fieldDidEndEditing(_:)), name: UITextView.textDidEndEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidChangeFrame(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // A drag-hide that leaves the field first responder with nothing on screen resigns it here. Only a hide ending
    // below the window counts: a panel/letters swap ends on screen.
    @objc private func keyboardWillHide(_ note: Notification) {
        guard isPresented, let field, let window = field.window,
              let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              window.convert(frame, from: window.screen.coordinateSpace).minY >= window.bounds.maxY - 1 else { return }
        _ = field.resignFirstResponder()
    }

    func install(in controller: UIViewController) {
        host = controller
        // Rotating with the panel up leaves the keyboard guide measuring the old size.
        rotation = controller.view.registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) { [weak self] (_: UIView, _) in
            self?.close()
        }
    }

    // Drops the composer's actions too; `close()` keeps them because the picker chips call them after closing.
    func uninstall() {
        close()
        detach()
        movingToNewField = false
        actions = nil
        if let rotation { host?.view.unregisterForTraitChanges(rotation) }
        rotation = nil
        host = nil
    }

    // Warmed up off the tap: building and laying out the chips and rail otherwise delays the keyboard animation.
    func warmUp() {
        guard panel == nil, let window = host?.view.window else { return }
        RecentPhotosLibrary.shared.prepare()
        let panel = makePanel(in: window)
        panel.frame = CGRect(origin: .zero, size: CGSize(width: window.bounds.width, height: KeyboardHeightCache.height(in: window)))
        panel.layoutIfNeeded()
    }

    private func makePanel(in window: UIWindow) -> AttachmentKeyboardView {
        let panel = self.panel ?? AttachmentKeyboardView(keyboard: self)
        self.panel = panel
        panel.prepare(height: KeyboardHeightCache.height(in: window), compact: window.traitCollection.verticalSizeClass == .compact,
                      safeArea: window.safeAreaInsets)
        return panel
    }

    func open(actions: AttachmentPanelActions, selection: [String], trayCount: Int) {
        self.actions = actions
        movingToNewField = false
        guard !isPresented else { update(selection: selection, trayCount: trayCount); return }
        guard let field = actions.field(), let window = field.window else { actions.dismissed(); return }
        // Sized before it becomes the input view, so it is presented at the last keyboard's height.
        _ = makePanel(in: window)
        update(selection: selection, trayCount: trayCount)
        present(in: field)
    }

    private func present(in field: UITextView) {
        attach(to: field)
        if field.isFirstResponder {
            field.reloadInputViews()
        } else if !field.becomeFirstResponder() {
            detach()
            actions?.dismissed()
        }
    }

    func showKeyboard() {
        movingToNewField = false
        guard let field, field.inputView != nil else { detach(); return }
        let reload = field.isFirstResponder
        detach()
        if reload { field.reloadInputViews() }
    }

    // Also puts away a panel still installed without focus (Select More is up, moving fields, waiting on the
    // message menu), so it cannot come back.
    func close() {
        let moving = movingToNewField
        movingToNewField = false
        restoresAfterMenu = false
        if isPresented, let field {
            pickingMore = nil
            closing = true
            _ = field.resignFirstResponder()
            closing = false
        } else if field != nil || moving {
            detach()
            actions?.dismissed()
        }
    }

    private func attach(to field: UITextView) {
        if self.field !== field { detach() }
        self.field = field
        guard let panel, field.inputView !== panel else { return }
        let assistant = field.inputAssistantItem
        assistantGroups = (assistant.leadingBarButtonGroups, assistant.trailingBarButtonGroups)
        assistant.leadingBarButtonGroups = []
        assistant.trailingBarButtonGroups = []
        field.inputView = panel
        field.addGestureRecognizer(fieldTap)
    }

    private func detach() {
        pickingMore = nil
        guard let field else { return }
        self.field = nil
        field.removeGestureRecognizer(fieldTap)
        if field.inputView === panel { field.inputView = nil }
        if let assistantGroups {
            field.inputAssistantItem.leadingBarButtonGroups = assistantGroups.leading
            field.inputAssistantItem.trailingBarButtonGroups = assistantGroups.trailing
        }
        assistantGroups = nil
    }

    @objc private func fieldTapped() {
        guard isPresented else { return }
        showKeyboard()
        actions?.dismissed()
    }

    @objc private func fieldDidEndEditing(_ note: Notification) {
        guard let field, note.object as? UITextView === field, pickingMore == nil else { return }
        detach()
        guard !closing else { actions?.dismissed(); return }
        // An appearance change rebuilds the composer (`.id(colorScheme)`); presenting again on the new field also
        // resolves the keyboard backdrop, which a live input view keeps from its presentation.
        movingToNewField = true
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, movingToNewField else { return }
            movingToNewField = false
            if field?.window == nil { moveToNewField() } else { actions?.dismissed() }
        }
    }

    private func moveToNewField() {
        guard let actions else { return }
        host?.view.layoutIfNeeded()
        guard let next = actions.field(), next.window != nil else { actions.dismissed(); return }
        UIView.performWithoutAnimation { present(in: next) }
    }

    func update(selection: [String], trayCount: Int) {
        panel?.update(selection: selection, trayCount: trayCount)
    }

    func menuWillPresent() { restoresAfterMenu = isPresented }

    // Returns true when the panel comes back, which it does unless the action takes the composer's place.
    func menuDismissed(composerTaken: Bool) -> Bool {
        defer { restoresAfterMenu = false }
        guard restoresAfterMenu, !composerTaken, let actions else { return false }
        actions.restore()
        return true
    }

    func select(_ asset: PHAsset) async { await actions?.select(asset) }
    func deselect(_ id: String) { actions?.deselect(id) }
    func refuse(_ reason: String) { actions?.refuse(reason) }

    // The panel and focus go first, then the picker comes up: the panel is no longer the input view when the
    // picker closes, so UIKit's responder restore has nothing to bring back. Files and the camera do the same.
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
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted { self?.presentCamera() } else { self?.refuse("Allow camera access in Settings to take a photo.") }
                }
            }
        default: refuse("Allow camera access in Settings to take a photo.")
        }
    }

    // Holds the capture action itself: the chat can uninstall the panel while the camera is up and the photo must
    // still land. Released when the camera closes so the composer is not retained.
    private func presentCamera() {
        guard let host, let actions, host.presentedViewController == nil, UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = camera
        camera.onCapture = actions.capture
        host.present(picker, animated: true)
    }

    // The panel stays up behind Select More; the completion covers a dismissal where UIKit does not refocus the field.
    func presentLimitedPicker() {
        guard let host, host.presentedViewController == nil else { return }
        let presentation = UUID()
        pickingMore = isPresented ? presentation : nil
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: host) { [weak self] _ in
            Task { @MainActor [weak self] in self?.limitedPickerClosed(presentation) }
        }
    }

    private func limitedPickerClosed(_ presentation: UUID) {
        guard pickingMore == presentation else { return }
        pickingMore = nil
        guard let field, !field.isFirstResponder else { return }
        if field.window == nil || !field.becomeFirstResponder() {
            detach()
            actions?.dismissed()
        }
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

extension AttachmentKeyboard: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private final class CameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var onCapture: ((CameraCapture) -> Void)?

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        defer { picker.dismiss(animated: true) }
        guard let onCapture else { return }
        self.onCapture = nil
        if let url = info[.mediaURL] as? URL {
            // The picker deletes its file once it closes; keep a copy for the export.
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { onCapture(.movie(copy)) }
        } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
            onCapture(.image(data))
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onCapture = nil
        picker.dismiss(animated: true)
    }
}

final class AttachmentKeyboardView: UIInputView {
    private let limitedRow = LimitedAccessRow()
    private let rail: RecentPhotosRail
    private let chips: FormatChipRow
    private var height: NSLayoutConstraint!
    private var top: NSLayoutConstraint!
    private var afterBanner: NSLayoutConstraint!
    private var chipHeight: NSLayoutConstraint!
    // Constraint constants, not layout margins (see `followSafeArea`).
    private var insetConstraints: [(NSLayoutConstraint, (UIEdgeInsets) -> CGFloat)] = []
    private var insets: UIEdgeInsets?
    private var compact = false

    init(keyboard: AttachmentKeyboard) {
        rail = RecentPhotosRail(keyboard: keyboard)
        chips = FormatChipRow(keyboard: keyboard)
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 335), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        // iOS 26 draws the keyboard backdrop behind an input view; the panel adds nothing of its own.
        backgroundColor = .clear
        accessibilityIdentifier = "attachmentPanel"
        limitedRow.onSelectMore = { [weak keyboard] in keyboard?.presentLimitedPicker() }
        limitedRow.onSettings = { [weak keyboard] in keyboard?.openSettings() }
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
        // Safe area insets are physical, so the sides pin to left and right.
        insetConstraints = [
            (limitedRow.leftAnchor.constraint(equalTo: leftAnchor), { $0.left + 16 }),
            (rightAnchor.constraint(equalTo: limitedRow.rightAnchor), { $0.right + 16 }),
            (rail.leftAnchor.constraint(equalTo: leftAnchor), { $0.left }),
            (rightAnchor.constraint(equalTo: rail.rightAnchor), { $0.right }),
            (chips.leftAnchor.constraint(equalTo: leftAnchor), { $0.left }),
            (rightAnchor.constraint(equalTo: chips.rightAnchor), { $0.right }),
            (bottomAnchor.constraint(equalTo: chips.bottomAnchor), { $0.bottom }),
        ]
        NSLayoutConstraint.activate([height, top, afterBanner, chipHeight, chips.topAnchor.constraint(equalTo: rail.bottomAnchor)]
                                    + insetConstraints.map(\.0))
        followSafeArea(.zero)
        // A rail that starts with an earlier chat's tiles also starts with its access row, so the warm-up lays out
        // the rail at the height it is presented at.
        if RecentPhotosLibrary.shared.isLimited { showLimitedRow(true) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare(height value: CGFloat, compact: Bool, safeArea: UIEdgeInsets) {
        if window == nil { followSafeArea(safeArea) }
        height.constant = value
        self.compact = compact
        chips.compact = compact
        applyMetrics()
        // A panel laid out before it was presented (the warm-up) would otherwise be presented at that size when the
        // keyboard has since been measured taller.
        if bounds.height != value {
            frame.size.height = value
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    func update(selection: [String], trayCount: Int) {
        rail.update(selection: selection, trayCount: trayCount)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        if window != nil { followSafeArea(safeAreaInsets) }
    }

    // Constraint constants let `prepare` apply the window's safe area before the panel has one; once presented,
    // the panel's side layout margins read 20 pt whatever was set (iOS 26.5).
    private func followSafeArea(_ safeArea: UIEdgeInsets) {
        let value = UIEdgeInsets(top: 0, left: safeArea.left, bottom: safeArea.bottom, right: safeArea.right)
        guard value != insets else { return }
        insets = value
        for (constraint, constant) in insetConstraints { constraint.constant = constant(value) }
        // Outside a window a constant change does not mark the panel for layout, and the warm-up's layout pass
        // would then keep the old insets.
        setNeedsLayout()
    }

    private func showLimitedRow(_ limited: Bool) {
        guard limitedRow.isHidden == limited else { return }
        limitedRow.isHidden = !limited
        applyMetrics()
    }

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

private final class LimitedAccessRow: UIView {
    var onSelectMore: () -> Void = {}
    var onSettings: () -> Void = {}
    private var collapse: NSLayoutConstraint!
    private weak var selectMore: UIButton?
    var collapsed = false { didSet { collapse.isActive = collapsed } }

    // Drawn as a small capsule but hit-testable 44 pt tall: the row extends 8 pt above and below its bounds.
    private static let reach: CGFloat = 8

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !collapsed && bounds.insetBy(dx: 0, dy: -Self.reach).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, self.point(inside: point, with: event) else { return nil }
        if let selectMore, selectMore.convert(selectMore.bounds, to: self).insetBy(dx: 0, dy: -Self.reach).contains(point) { return selectMore }
        return super.hitTest(point, with: event)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let label = UILabel()
        label.text = "You've given access to a selection of photos."
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        // Always one line: the text shrinks to fit instead of wrapping.
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        var configuration = UIButton.Configuration.glass()
        configuration.title = "Select More"
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        let selectMore = UIButton(configuration: configuration)
        self.selectMore = selectMore
        selectMore.tintColor = .label
        selectMore.accessibilityIdentifier = "selectMorePhotos"
        selectMore.addAction(UIAction { [weak self] _ in self?.onSelectMore() }, for: .primaryActionTriggered)
        // A tap adds photos straight away; the settings route stays one long press (or VoiceOver action) away.
        selectMore.menu = UIMenu(children: [
            UIAction(title: "Change Settings", image: UIImage(systemName: "gear")) { [weak self] _ in self?.onSettings() },
        ])
        selectMore.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Change Settings") { [weak self] _ in self?.onSettings(); return true },
        ]
        selectMore.setContentHuggingPriority(.required, for: .horizontal)
        selectMore.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, selectMore])
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

// Reads the library off the main thread: the first PhotoKit call connects to photolibraryd and can take tens of ms.
private final class RecentPhotosSource: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    // `PHFetchResult` is documented thread-safe.
    struct Batch: @unchecked Sendable { let assets: PHFetchResult<PHAsset> }
    private let queue = DispatchQueue(label: "haus.xmpp.ios.recentPhotos", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    // Touched only on `queue` and in deinit, which cannot run while a queued block still holds `self`.
    private var observing = false
    @MainActor var onChange: () -> Void = {}

    deinit { if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }

    func invalidate() { lock.withLock { generation += 1 } }

    // A PhotoKit call too, so it runs on the queue; it never prompts.
    func status(_ completion: @escaping @MainActor (PHAuthorizationStatus) -> Void) {
        queue.async {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(status) } }
        }
    }

    // Registers the change observer on first use.
    func fetch(limit: Int, completion: @escaping @MainActor (Batch) -> Void) {
        let mine = lock.withLock { generation += 1; return generation }
        queue.async { [self] in
            if !observing {
                PHPhotoLibrary.shared().register(self)
                observing = true
            }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            options.fetchLimit = limit
            let assets: PHFetchResult<PHAsset>
            if let library = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject {
                assets = PHAsset.fetchAssets(in: library, options: options)
            } else {
                assets = PHAsset.fetchAssets(with: options)
            }
            let batch = Batch(assets: assets)
            DispatchQueue.main.async {
                guard self.lock.withLock({ self.generation }) == mine else { return }
                MainActor.assumeIsolated { completion(batch) }
            }
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.onChange() }
    }
}

// Shared across chats, so the PhotoKit connection, observer and first fetch happen once per process. Nothing
// touches PhotoKit until a panel has opened once on this install, where access is asked.
@MainActor final class RecentPhotosLibrary {
    static let shared = RecentPhotosLibrary()
    static let limit = 96
    lazy var imageManager = PHCachingImageManager()
    private let source = RecentPhotosSource()
    private(set) var assets: PHFetchResult<PHAsset>?
    private var readUnder: PHAuthorizationStatus?
    var isLimited: Bool { assets != nil && readUnder == .limited }
    private let rails = NSHashTable<RecentPhotosRail>.weakObjects()

    private init() {
        source.onChange = { [weak self] in self?.libraryChanged() }
    }

    func attach(_ rail: RecentPhotosRail) { rails.add(rail) }

    private static let askedKey = "attachmentKeyboard.photosAsked"

    static func panelOpened() {
        if !UserDefaults.standard.bool(forKey: askedKey) { UserDefaults.standard.set(true, forKey: askedKey) }
    }

    // Never asks for access; a panel that opened meanwhile has the last word.
    func prepare() {
        guard readUnder == nil, UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        source.status { [weak self] status in
            guard let self, readUnder == nil, status == .authorized || status == .limited else { return }
            read(under: status)
        }
    }

    // A read under the same access is kept current by the observer; otherwise the library is read again.
    func refresh(_ status: PHAuthorizationStatus) {
        guard status == .authorized || status == .limited else { revoke(); return }
        guard status != readUnder else { return }
        read(under: status)
    }

    func revoke() {
        source.invalidate()
        assets = nil
        readUnder = nil
    }

    private func libraryChanged() {
        // Only a library this process has read has an observer; the access may have changed with it.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            revoke()
            for rail in rails.allObjects { rail.accessChanged() }
            return
        }
        read(under: status)
    }

    private func read(under status: PHAuthorizationStatus) {
        readUnder = status
        source.fetch(limit: Self.limit) { [weak self] batch in
            guard let self else { return }
            assets = batch.assets
            for rail in rails.allObjects { rail.show(batch.assets, limited: status == .limited) }
        }
    }
}

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
            chips.append(("Camera", "camera.fill", "attachCamera", { [weak keyboard] in keyboard?.takePhoto() }))
        }
        chips.append(("Photos", "photo.on.rectangle.angled", "attachPhotos", { [weak keyboard] in keyboard?.pickPhotos() }))
        chips.append(("File", "doc", "attachFiles", { [weak keyboard] in keyboard?.pickFiles() }))
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
        // Set on the configuration because glass buttons otherwise apply `.large` symbol scale.
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular, scale: .medium)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            // Next run loop, so the pressed glass shows before the panel goes.
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

    // The spring starts on the next run loop: starting it while UIKit presents the panel delays the panel's slide.
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
        DispatchQueue.main.async { animator.startAnimation() }
    }
}
