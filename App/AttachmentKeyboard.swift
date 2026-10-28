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
    /// The composer's text view, whose input view the panel becomes; looked up on each use, as SwiftUI rebuilds it.
    var field: () -> UITextView?
    /// Prepares a recent photo into the tray; returns once it landed there or was refused.
    var select: (PHAsset) async -> Void
    /// Takes a recent photo back out of the tray.
    var deselect: (String) -> Void
    var capture: (CameraCapture) -> Void
    var photos: () -> Void
    var files: () -> Void
    /// A reason shown to the user: the tray is full, the camera is not allowed.
    var refuse: (String) -> Void
    /// The panel went away without the composer asking: a tap on the field brought the letters back, or the field
    /// lost its focus (a drag, the message menu).
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

/// Makes the attachment panel the composer field's own keyboard: its `inputView`, swapped with the letters by
/// `reloadInputViews()` while the field stays first responder. UIKit then treats the panel as the keyboard: it slides
/// with the keyboard curve, the keyboard layout guide follows it, and a drag on the timeline dismisses it. Swapping in
/// place, rather than handing first responder to another view, keeps the height still and leaves UIKit only one
/// responder to restore. The timeline controller installs it, for the presentations and the rotation dismissal.
@MainActor final class AttachmentKeyboard: NSObject {
    private(set) weak var host: UIViewController?
    private var panel: AttachmentKeyboardView?
    private var actions: AttachmentPanelActions?
    /// The composer's text view while the panel is its input view.
    private weak var field: UITextView?
    /// The field's own assistant bar groups, put back when the letters return (they show above the keyboard on iPad).
    private var assistantGroups: (leading: [UIBarButtonItemGroup], trailing: [UIBarButtonItemGroup])?
    /// While the panel is up, a tap on the field brings the letters back, as it does in Signal.
    private lazy var fieldTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(fieldTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()
    /// The field ended editing on its own: the next turn tells a dismissal from SwiftUI replacing the field.
    private var movingToNewField = false
    /// `close()` is resigning the field.
    private var closing = false
    /// The limited-library picker is up over the panel. Presenting it takes the field's focus and UIKit gives it back,
    /// panel and all, when the picker closes, so the panel stays attached meanwhile.
    private var pickingMore = false
    private var restoresAfterMenu = false
    private var rotation: UITraitChangeRegistration?
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

    /// A drag that hides the panel is expected to end the field's editing; should it leave the field first responder
    /// with nothing on screen, resigning here is what turns the × back into a +. Only a hide that ends below the
    /// window counts: a swap between the panel and the letters ends on screen.
    @objc private func keyboardWillHide(_ note: Notification) {
        guard isPresented, let field, let window = field.window,
              let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              window.convert(frame, from: window.screen.coordinateSpace).minY >= window.bounds.maxY - 1 else { return }
        _ = field.resignFirstResponder()
    }

    func install(in controller: UIViewController) {
        host = controller
        // Rotating with the panel up leaves the keyboard guide measuring the old size (Signal dismisses here too).
        rotation = controller.view.registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) { [weak self] (_: UIView, _) in
            self?.close()
        }
    }

    /// Also drops the composer's actions, which hold the composer that owns this keyboard. `close()` keeps them for
    /// the picker chips, which call them after closing the panel. A camera still up keeps its own route to the
    /// composer (see `presentCamera`).
    func uninstall() {
        close()
        detach()
        movingToNewField = false
        pickingMore = false
        actions = nil
        if let rotation { host?.view.unregisterForTraitChanges(rotation) }
        rotation = nil
        host = nil
    }

    /// Builds and lays out the panel once the chat is on screen, so the first "+" only presents it. Building the
    /// glass chips and the rail, and their first layout, measured 60-100 ms of main-thread time in a Debug build
    /// when they ran between the tap and the start of the keyboard animation. Once a panel has asked for photo
    /// access (in any earlier run), the first chat after launch also reads the recent photos ahead, off the main
    /// thread, when the user allowed it.
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

    /// Puts the panel in place of the letters, or brings it up with the field when the field had no focus.
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

    /// The letters again, in place of the panel; the field keeps its focus, so the keyboard keeps its height.
    func showKeyboard() {
        movingToNewField = false
        guard let field, field.inputView != nil else { detach(); return }
        let reload = field.isFirstResponder
        detach()
        if reload { field.reloadInputViews() }
    }

    /// Puts the panel away, and the field's focus with it.
    func close() {
        movingToNewField = false
        guard isPresented, let field else { return }
        closing = true
        _ = field.resignFirstResponder()
        closing = false
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

    /// Leaves the field as SwiftUI made it. A field that never shows the panel again (a sheet over it, a later focus)
    /// then comes back with the letters.
    private func detach() {
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
        guard let field, note.object as? UITextView === field, !pickingMore else { return }
        detach()
        guard !closing else { actions?.dismissed(); return }
        // An appearance change rebuilds the composer (`.id(colorScheme)`): the old field ends editing as it leaves the
        // window, which it has not left yet. Presenting the panel again on the new field also resolves the keyboard
        // backdrop for the new look, which a live input view keeps from when it was presented.
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

    /// Signal's order: the panel goes first, then the full-screen picker comes up over a settled screen. The field
    /// gives up its focus with the panel, and the panel is no longer its input view when the picker closes: the chat
    /// is left as it was before "+", with the picks in the tray, and UIKit's restore of the responder that was first
    /// when the picker came up has nothing to bring back. The same goes for Files and the camera.
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

    /// The camera holds the composer's capture action itself, not the panel's actions: the chat can stop offering
    /// uploads while the camera is up, which uninstalls the panel, and the photo must still land. It lets go of the
    /// action when the camera closes, so the composer is not kept alive past the capture.
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

    /// Select More is part of the panel, so the panel is up again when the picker closes. UIKit gives the field
    /// back its focus itself; the completion covers a dismissal that does not.
    func presentLimitedPicker() {
        guard let host else { return }
        pickingMore = isPresented
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: host) { [weak self] _ in
            Task { @MainActor [weak self] in self?.limitedPickerClosed() }
        }
    }

    private func limitedPickerClosed() {
        guard pickingMore else { return }
        pickingMore = false
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
    /// The field's own taps still place the caret.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private final class CameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    /// Set for one presentation and cleared when it ends.
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

// MARK: - Panel

/// Replaces the software keyboard: an optional limited-access row, the recent photos rail and the format chips.
final class AttachmentKeyboardView: UIInputView {
    private let limitedRow = LimitedAccessRow()
    private let rail: RecentPhotosRail
    private let chips: FormatChipRow
    private var height: NSLayoutConstraint!
    private var top: NSLayoutConstraint!
    private var afterBanner: NSLayoutConstraint!
    private var chipHeight: NSLayoutConstraint!
    /// The parts' side and bottom insets: the safe area, never the view's layout margins (see `followSafeArea`).
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
        // The safe area is physical (left, right), so the sides pin to left and right; the parts lay out their own
        // content in the reading direction.
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

    /// `safeArea` is the window's; a presented panel follows its own safe area instead.
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

    /// The parts sit inside the safe area through constraint constants, which `prepare` can set from the window's
    /// safe area before the panel has one of its own: a warm-up laid out without the home indicator inset made the
    /// rail 34 pt taller than it is once presented, so the tiles were sized and drawn again on the tap. Layout
    /// margins cannot carry this: once presented, the panel's side margins read 20 pt whatever was set (iOS 26.5),
    /// which pulled the rail in from the screen edges.
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

/// "You've given access to a selection of photos" plus a Select More button.
private final class LimitedAccessRow: UIView {
    var onSelectMore: () -> Void = {}
    var onSettings: () -> Void = {}
    private var collapse: NSLayoutConstraint!
    private weak var selectMore: UIButton?
    var collapsed = false { didSet { collapse.isActive = collapsed } }

    /// The button stays a small capsule beside one line of footnote text, but takes touches 44pt tall: the row, and
    /// the button through it, answer 8pt above and below their drawn bounds (the rail starts 16pt below).
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

// MARK: - Recent photos

/// Reads the library off the main thread. The first PhotoKit call in a process connects to photolibraryd
/// (measured 60 ms in the simulator, more with a large library and its sorted fetch); on the main thread that ran
/// between the tap and the start of the keyboard animation.
private final class RecentPhotosSource: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    /// `PHFetchResult` is documented thread-safe; the box carries it back to the main actor.
    struct Batch: @unchecked Sendable { let assets: PHFetchResult<PHAsset> }
    private let queue = DispatchQueue(label: "haus.xmpp.ios.recentPhotos", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    /// Touched only on `queue`, and in deinit, which cannot run while a queued block still holds `self`.
    private var observing = false
    /// The library changed; called on the main actor.
    @MainActor var onChange: () -> Void = {}

    deinit { if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }

    /// Outcomes of fetches started before this call are dropped.
    func invalidate() { lock.withLock { generation += 1 } }

    /// The photo access the user gave, read on the queue: it is a PhotoKit call too, and never prompts.
    func status(_ completion: @escaping @MainActor (PHAuthorizationStatus) -> Void) {
        queue.async {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(status) } }
        }
    }

    /// The newest `limit` photos and videos of the user library; the change observer is registered on first use.
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

/// The recent photos every chat's panel shows, read once per process. Each chat used to build its own source, so
/// every chat paid the PhotoKit connection, the observer registration and the first fetch again on its first "+".
/// The fetch result stays current through the change observer; a panel opening under a different access (limited
/// to full, or a new grant) reads again. The panel asks for access on its first open; until a panel has opened
/// once on this install, nothing here touches PhotoKit, so a warm-up before that does no photo work at all.
@MainActor private final class RecentPhotosLibrary {
    static let shared = RecentPhotosLibrary()
    static let limit = 96
    /// Shared, so a chat opened later does not start with an empty image cache. Made with the first tile.
    lazy var imageManager = PHCachingImageManager()
    private let source = RecentPhotosSource()
    /// The last read and the access it was made under; `nil` until the first read lands, or after a denial.
    private(set) var assets: PHFetchResult<PHAsset>?
    private var readUnder: PHAuthorizationStatus?
    /// The read on hand was made under limited access.
    var isLimited: Bool { assets != nil && readUnder == .limited }
    private let rails = NSHashTable<RecentPhotosRail>.weakObjects()

    private init() {
        source.onChange = { [weak self] in self?.libraryChanged() }
    }

    func attach(_ rail: RecentPhotosRail) { rails.add(rail) }

    /// Set when a panel first opens, which is where access is asked; kept across launches with the install.
    private static let askedKey = "attachmentKeyboard.photosAsked"

    static func panelOpened() {
        if !UserDefaults.standard.bool(forKey: askedKey) { UserDefaults.standard.set(true, forKey: askedKey) }
    }

    /// After a chat appears: reads ahead when access was given earlier, so the first "+" finds the tiles. It
    /// never asks, does nothing before a panel has asked, and a panel that opened meanwhile has the last word.
    func prepare() {
        guard readUnder == nil, UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        source.status { [weak self] status in
            guard let self, readUnder == nil, status == .authorized || status == .limited else { return }
            read(under: status)
        }
    }

    /// A panel is opening, or a warm-up learned the access. A read under the same access is kept (the observer
    /// keeps it current) or still on its way; otherwise the library is read again.
    func refresh(_ status: PHAuthorizationStatus) {
        guard status == .authorized || status == .limited else { revoke(); return }
        guard status != readUnder else { return }
        read(under: status)
    }

    /// Access is gone: drop the read and any read still on its way.
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

/// Up to 96 of the newest photos and videos, square tiles in one sideways row. Tapping adds to the tray in tap
/// order; tapping a selected tile takes it back out.
private final class RecentPhotosRail: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    /// Weak, like every reference back from the panel: UIKit keeps the last panel it showed after the chat that
    /// owned the keyboard has gone, and a chip's action runs a turn after its tap.
    private weak var keyboard: AttachmentKeyboard?
    private let layout = UICollectionViewFlowLayout()
    private let collection: UICollectionView
    private let library = RecentPhotosLibrary.shared
    private var assets: PHFetchResult<PHAsset>?
    private var selection: [String] = []
    private var trayCount = 0
    private var loading: Set<String> = []
    private var itemSide: CGFloat = 0
    var onAccessChanged: (Bool) -> Void = { _ in }

    init(keyboard: AttachmentKeyboard) {
        self.keyboard = keyboard
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 12
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        // A library read by an earlier chat fills the rail during the warm-up's layout, not on the tap.
        assets = library.assets
        library.attach(self)
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.alwaysBounceHorizontal = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(RecentPhotoCell.self, forCellWithReuseIdentifier: "photo")
        collection.accessibilityIdentifier = "recentPhotos"
        addSubview(collection)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        guard height > 0 else { collection.frame = bounds; return }
        // Two rows only once the rail is tall enough (iPad); a phone keeps one row of full-height squares.
        let side = height > 250 ? floor((height - 12) / 2) : height
        let inset: CGFloat = bounds.width >= 430 ? 20 : 16
        let resized = abs(side - itemSide) > 0.5 || layout.sectionInset.left != inset
        if resized {
            itemSide = side
            layout.itemSize = CGSize(width: side, height: side)
            layout.sectionInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            layout.invalidateLayout()
        }
        // The tiles take their size before the collection takes the rail's: the other way round (autoresizing), a
        // rail shortened by the limited-access row briefly held tiles taller than itself and UIKit logged an
        // invalid flow layout size.
        if collection.frame != bounds { collection.frame = bounds }
        if resized { collection.reloadData() }
    }

    /// Asked for on first open only, never at launch.
    func present() {
        RecentPhotosLibrary.panelOpened()
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
            library.revoke()
            accessChanged()
            return
        }
        library.refresh(status)
        // A read this rail has not shown yet goes up now; with none yet, the rail stays blank until one lands.
        if let latest = library.assets, latest !== assets {
            show(latest, limited: status == .limited)
        } else {
            collection.backgroundView = assets == nil ? nil : emptyMessage()
        }
    }

    /// A read landed (this panel's, another chat's, or a library change).
    func show(_ latest: PHFetchResult<PHAsset>, limited: Bool) {
        onAccessChanged(limited)
        assets = latest
        collection.reloadData()
        collection.backgroundView = emptyMessage()
        // A panel that is not up makes its first cells now, not when "+" presents it. The read can turn the
        // limited-access row on, which shortens the rail, so the whole panel lays out again first and the cells are
        // made at the size they are presented at, not sized and reloaded again on the tap. Outside a window the
        // row's constraint changes do not mark the panel for layout, so it is marked here.
        if window == nil {
            superview?.setNeedsLayout()
            superview?.layoutIfNeeded()
            collection.layoutIfNeeded()
        }
    }

    /// Access was denied or taken away.
    func accessChanged() {
        onAccessChanged(false)
        assets = nil
        collection.reloadData()
        showAccessPrompt()
    }

    private func emptyMessage() -> UIView? {
        (assets?.count ?? 0) == 0 ? message("No recent photos", button: nil) : nil
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
            guard let path = collection.indexPath(for: cell), let asset = asset(at: path.item) else { continue }
            configureState(cell, asset: asset, index: path.item)
        }
    }

    private func showAccessPrompt() {
        let denied = PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined
        collection.backgroundView = message("Allow photo access to pick from your recent photos.", button: denied ? "Open Settings" : "Allow Access") { [weak self] in
            if denied { self?.keyboard?.openSettings() } else {
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

    /// `object(at:)` raises for an index past the end. Until the next layout pass after a reload, the visible cells
    /// keep their old index paths, which a smaller read no longer has.
    private func asset(at item: Int) -> PHAsset? {
        guard let assets, item < assets.count else { return nil }
        return assets.object(at: item)
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { assets?.count ?? 0 }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! RecentPhotoCell
        guard let asset = asset(at: indexPath.item) else { return cell }
        cell.show(asset: asset, manager: library.imageManager, side: itemSide, scale: traitCollection.displayScale)
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
        guard let keyboard, let asset = asset(at: indexPath.item) else { return }
        let id = asset.localIdentifier
        if selection.contains(id) { keyboard.deselect(id); return }
        guard !loading.contains(id) else { return }
        guard trayCount + loading.count < ComposerPlan.trayLimit else {
            keyboard.refuse("You can attach up to \(ComposerPlan.trayLimit) files at a time.")
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
        // Sendable, so the handler is not main-actor code. Written here it otherwise would be, and Swift checks that
        // on entry, which would trap if PhotoKit answered on a queue of its own. PhotoKit documents the main thread
        // only as the typical case, so this is defensive. An answer on the main thread, such as the quick first one,
        // is shown at once.
        request = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { @Sendable [weak self] image, _ in
            let apply = { @MainActor in
                guard let self, self.assetID == id else { return }
                self.imageView.image = image
            }
            if Thread.isMainThread { MainActor.assumeIsolated(apply) } else { DispatchQueue.main.async(execute: apply) }
        }
        let isVideo = asset.mediaType == .video
        durationLabel.isHidden = !isVideo
        scrim.isHidden = !isVideo
        // Int(_:) traps on a NaN or infinite value, and PhotoKit does not promise a finite duration.
        let seconds = asset.duration.isFinite ? Int(min(max(asset.duration, 0), 359_999).rounded()) : 0
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
        // Signal's "28" is a 28 pt asset canvas with about 22-24 pt of ink. A 22 pt regular symbol at medium
        // scale draws that ink; set on the configuration, because glass buttons otherwise apply `.large` scale.
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular, scale: .medium)
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

    /// Each chip springs from half size, a third of the duration after the one before it. The chips hide at once,
    /// so the panel never shows them at full size, but the spring starts on the next turn of the run loop: started
    /// while UIKit presents the panel, it put about 7 ms (Release, simulator) between the "+" and the start of the
    /// panel's slide, on every open.
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
