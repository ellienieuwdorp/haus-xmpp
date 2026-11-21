import AppKit
import SwiftUI

@MainActor final class MacToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "main")
    private let model: AppModel
    private let state: MacWindowState
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private weak var accountButton: MacAccountButton?
    private weak var window: NSWindow?
    private lazy var chatHeader = MacChatHeaderButton(target: self, action: #selector(toggleDetails))
    // Each drawn again only when it changes.
    private var accountPicture: (account: String, image: NSImage?, dimmed: Bool)?
    private var chatPicture: (chatID: String, initial: Character?, image: NSImage?, isGroup: Bool)?
    private var avatarRequest: String?
    // Rolls a relative "Last seen" over while one shows.
    private var lastSeenTicks: Task<Void, Never>?

    private static let account = NSToolbarItem.Identifier("account")
    private static let attention = NSToolbarItem.Identifier("attention")
    private static let newChat = NSToolbarItem.Identifier("newChat")
    private static let chatHeaderItem = NSToolbarItem.Identifier("chatHeader")
    private static let refresh = NSToolbarItem.Identifier("refresh")

    init(model: AppModel, state: MacWindowState) {
        self.model = model
        self.state = state
        super.init()
    }

    func install(in window: NSWindow) {
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        self.window = window
        MacObservation.track(self) { toolbar in toolbar.update() }
        // Tracked apart, so typing and presence never rerun the rest of the toolbar.
        MacObservation.track(self) { toolbar in toolbar.updateChatHeader() }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.account, Self.attention, Self.newChat, .toggleSidebar, .sidebarTrackingSeparator,
         Self.chatHeaderItem, .flexibleSpace, .inspectorTrackingSeparator, Self.refresh]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        item.autovalidates = false
        switch identifier {
        case Self.account:
            // A spinner item of its own beside the picture would make the toolbar tile the group again each time it
            // came and went, so progress spins inside the picture's circle.
            let button = MacAccountButton(target: self, action: #selector(showAccount))
            item.view = button
            item.label = "Account"
            let menuItem = NSMenuItem(title: "Account", action: #selector(showAccount), keyEquivalent: "")
            menuItem.target = self
            item.menuFormRepresentation = menuItem
            accountButton = button
        case Self.attention:
            item.label = "Encryption setup needs attention"
            item.toolTip = "Encryption setup needs attention"
            item.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: item.label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
            item.isBordered = true
            item.action = #selector(showSettings)
        case Self.newChat:
            item.label = "New Chat"
            item.toolTip = "New Chat (⌘N)"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Chat")
            item.isBordered = true
            item.action = #selector(newChat)
        case Self.chatHeaderItem:
            // Measured and laid out in AppKit, so the toolbar's tiling on each step of a resize never asks SwiftUI for a
            // size. It is the one control for the details; ⌥⌘I and the Chat menu do the same.
            item.view = chatHeader
            item.label = "Chat Details"
            item.isBordered = true
            item.isNavigational = true
            let menuItem = NSMenuItem(title: "Chat Details", action: #selector(toggleDetails), keyEquivalent: "")
            menuItem.target = self
            item.menuFormRepresentation = menuItem
        case Self.refresh:
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.label = "Refresh"
            item.isBordered = true
            item.action = #selector(refresh)
        default:
            return nil
        }
        items[identifier] = item
        return item
    }

    private func update() {
        let signedIn = !model.accountID.isEmpty
        var connecting = model.isSettlingConnection || model.isCatchingUp
        #if DEBUG
        if MacDebugHooks.tour.connecting { connecting = true }
        #endif
        if let button = accountButton {
            button.toolTip = signedIn ? model.accountID : "Sign in"
            // Faded under the spinner, which reads over any picture.
            let picture = (account: model.accountID, image: model.avatars[model.accountID], dimmed: connecting)
            if accountPicture?.account != picture.account || accountPicture?.image !== picture.image || accountPicture?.dimmed != picture.dimmed {
                accountPicture = picture
                button.image = Self.render(ChatAvatar(key: picture.account, name: Self.initial(of: picture.account), image: picture.image, size: 22)
                                               .opacity(picture.dimmed ? 0.4 : 1),
                                           label: "Account")
            }
            button.progress = connecting ? (model.isCatchingUp ? "Catching up" : "Connecting") : nil
        }
        items[Self.attention]?.isHidden = connecting || !model.connectionNeedsAttention
        items[Self.newChat]?.isEnabled = signedIn
        let page = state.inspectorShown && state.selection != nil ? state.inspectorPath.last : nil
        switch page {
        case .encryption: items[Self.refresh]?.toolTip = "Refresh devices"
        case .groupDetails: items[Self.refresh]?.toolTip = "Refresh group"
        default: break
        }
        items[Self.refresh]?.isHidden = refreshRoute(page) == nil
        items[Self.refresh]?.isEnabled = model.session.isReady
    }

    // The pill carries the chat's name and subtitle, so the window keeps its title for the Window menu, Mission Control
    // and VoiceOver but draws none in the toolbar while a chat is open.
    private func updateChatHeader() {
        let selection = state.selection
        let visibility: NSWindow.TitleVisibility = selection == nil ? .visible : .hidden
        if window?.titleVisibility != visibility { window?.titleVisibility = visibility }
        items[Self.chatHeaderItem]?.isHidden = selection == nil
        guard let chatID = selection else {
            lastSeenTicks?.cancel()
            lastSeenTicks = nil
            return
        }
        let name = model.chatName(for: chatID)
        chatHeader.show(name: name, subtitle: MacChatSubtitle.text(model: model, chatID: chatID, now: .now), detailsShown: state.inspectorShown)
        let picture = (chatID: chatID, initial: name.first, image: model.avatar(for: chatID), isGroup: model.isGroup(chatID))
        if chatPicture?.chatID != picture.chatID || chatPicture?.initial != picture.initial || chatPicture?.image !== picture.image
            || chatPicture?.isGroup != picture.isGroup {
            chatPicture = picture
            chatHeader.avatar = Self.render(ChatAvatar(key: chatID, name: name, image: picture.image, isGroup: picture.isGroup,
                                                       size: MacChatHeaderButton.avatarSize), label: name)
        }
        let request = "\(chatID)|\(model.session.isReady)"
        if avatarRequest != request {
            avatarRequest = request
            let model = model
            Task { await model.loadAvatar(for: chatID) }
        }
        if case .lastSeen = model.openChatLastSeen {
            guard lastSeenTicks == nil else { return }
            lastSeenTicks = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, !Task.isCancelled else { return }
                    self.updateChatHeader()
                }
            }
        } else {
            lastSeenTicks?.cancel()
            lastSeenTicks = nil
        }
    }

    private func refreshRoute(_ page: ChatRoute?) -> ChatRoute? {
        switch page {
        case .encryption, .groupDetails: page
        default: nil
        }
    }

    @objc private func showAccount() { state.showingAccount = true }
    @objc private func newChat() { state.showingNewChat = true }
    @objc private func toggleDetails() { state.inspectorShown.toggle() }
    @objc private func showSettings() { MacSettingsOpening.open() }

    @objc private func refresh() {
        let model = model
        switch state.inspectorPath.last {
        case .encryption(let chatID): Task { await model.loadEncryptionDetails(for: chatID, force: true) }
        case .groupDetails(let room): Task { await model.loadGroupDetails(room: room) }
        default: break
        }
    }

    private static func initial(of account: String) -> String {
        String((account.split(separator: "@").first ?? "").prefix(1)).uppercased()
    }

    private static func render(_ view: some View, label: String) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }
}

// Sized by the picture alone, the spinner's place fixed, so the toolbar lays it out the same with or without progress.
private final class MacAccountButton: NSButton {
    private let spinner = NSProgressIndicator()

    var progress: String? {
        didSet {
            guard progress != oldValue else { return }
            spinner.isHidden = progress == nil
            if progress == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
            setAccessibilityValue(progress)
        }
    }

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        bezelStyle = .toolbar
        imagePosition = .imageOnly
        self.target = target
        self.action = action
        setAccessibilityLabel("Account")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        // Over the button's own drawing, which AppKit puts below its subviews.
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16), spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === spinner ? self : hit
    }
}

// One VoiceOver element and one key view: the avatar and the two lines are drawing only. The name truncates as the
// toolbar narrows the item towards its minimum.
private final class MacChatHeaderButton: NSButton {
    static let avatarSize: CGFloat = 28
    private static let avatarInset: CGFloat = 4
    private static let textGap: CGFloat = 8
    private static let trailingInset: CGFloat = 12
    private static let maximumWidth: CGFloat = 260
    private static let minimumWidth: CGFloat = 120

    var avatar: NSImage? {
        get { avatarView.image }
        set { avatarView.image = newValue }
    }

    private let avatarView = MacAvatarImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var textWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 0
    private var contentWidth = minimumWidth
    private lazy var minimumWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth)

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        bezelStyle = .toolbar
        title = ""
        imagePosition = .noImage
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        nameField.textColor = .labelColor
        subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleField.textColor = .secondaryLabelColor
        for field in [nameField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
        }
        for view in [avatarView, nameField, subtitleField] as [NSView] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        // Hugs its content up to the maximum and, short of room, yields width down to the minimum.
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        minimumWidthConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // A view that allows vibrancy is drawn vibrant along with its subviews, which turns the avatar grey on the
    // toolbar's glass.
    override var allowsVibrancy: Bool { false }

    func show(name: String, subtitle: String, detailsShown: Bool) {
        if nameField.stringValue != name { nameField.stringValue = name }
        if subtitleField.stringValue != subtitle { subtitleField.stringValue = subtitle }
        subtitleField.isHidden = subtitle.isEmpty
        setAccessibilityLabel(subtitle.isEmpty ? name : "\(name), \(subtitle)")
        setAccessibilityHelp(detailsShown ? "Hides the chat's details." : "Shows the chat's details.")
        toolTip = detailsShown ? "Hide the chat's details (⌥⌘I)" : "Show the chat's details (⌥⌘I)"
        // Intrinsic text widths are fractional; the extra point keeps a fitting line from truncating after rounding.
        let width = max(nameField.intrinsicContentSize.width, subtitle.isEmpty ? 0 : subtitleField.intrinsicContentSize.width)
        textWidth = width.rounded(.up) + 1
        measure(height: bounds.height > 0 ? bounds.height : naturalHeight)
        needsLayout = true
    }

    // The bezel's own height, so the pill lines up with the toolbar's other buttons, unless two lines need more. The
    // height counts the subtitle line even when it is empty, so the pill keeps its height as a subtitle comes and goes.
    private var naturalHeight: CGFloat {
        let lines = nameField.intrinsicContentSize.height + subtitleField.intrinsicContentSize.height
        return max(super.intrinsicContentSize.height, lines.rounded(.up))
    }

    override var intrinsicContentSize: NSSize { NSSize(width: contentWidth, height: naturalHeight) }

    // The toolbar sets the item's height, and the avatar's size and inset follow it, so the width is measured again
    // for each height the pill gets.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.height != measuredHeight { measure(height: newSize.height) }
    }

    private func measure(height: CGFloat) {
        measuredHeight = height
        let width = min(Self.maximumWidth, (Self.textX(height: height) + textWidth + Self.trailingInset).rounded(.up))
        guard width != contentWidth else { return }
        contentWidth = width
        minimumWidthConstraint.constant = min(width, Self.minimumWidth)
        invalidateIntrinsicContentSize()
    }

    // Inset the same on every side, so the circle sits concentric in the capsule's leading end.
    private static func avatarFrame(height: CGFloat) -> NSRect {
        let side = max(0, min(avatarSize, height - 2 * avatarInset))
        let inset = (height - side) / 2
        return NSRect(x: inset, y: inset, width: side, height: side)
    }

    private static func textX(height: CGFloat) -> CGFloat { avatarFrame(height: height).maxX + textGap }

    override func layout() {
        super.layout()
        avatarView.frame = Self.avatarFrame(height: bounds.height)
        let x = Self.textX(height: bounds.height)
        let width = max(0, bounds.width - x - Self.trailingInset)
        let nameHeight = nameField.intrinsicContentSize.height
        let subtitleHeight = subtitleField.isHidden ? 0 : subtitleField.intrinsicContentSize.height
        let top = (bounds.height - nameHeight - subtitleHeight) / 2
        func line(from offset: CGFloat, height: CGFloat) -> NSRect {
            NSRect(x: x, y: isFlipped ? offset : bounds.height - offset - height, width: width, height: height)
        }
        nameField.frame = line(from: top, height: nameHeight)
        subtitleField.frame = line(from: top + nameHeight, height: subtitleHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

// A picture that is not a template draws in colour only outside vibrancy, as the account button's image does.
private final class MacAvatarImageView: NSImageView {
    override var allowsVibrancy: Bool { false }
}

@MainActor enum MacSettingsOpening {
    static func open() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
