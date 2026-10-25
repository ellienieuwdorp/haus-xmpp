import AppKit
import SwiftUI

/// The main window's toolbar, with the split view's tracking separators: over the sidebar the account, connection
/// progress and New Chat, then the sidebar button at its edge; over the conversation the chat's picture before its name
/// (the window's title); over the inspector a pushed page's Refresh; and Chat Details at the trailing edge.
@MainActor final class MacToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "main")
    private let model: AppModel
    private let state: MacWindowState
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private weak var spinner: NSProgressIndicator?
    /// What the account picture was drawn from, so it is drawn again only when that changes.
    private var accountPicture: (account: String, image: NSImage?)?

    private static let account = NSToolbarItem.Identifier("account")
    private static let connecting = NSToolbarItem.Identifier("connecting")
    private static let attention = NSToolbarItem.Identifier("attention")
    private static let newChat = NSToolbarItem.Identifier("newChat")
    private static let chatPicture = NSToolbarItem.Identifier("chatPicture")
    private static let refresh = NSToolbarItem.Identifier("refresh")
    private static let details = NSToolbarItem.Identifier("details")

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
        MacObservation.track(self) { toolbar in toolbar.update() }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.account, Self.connecting, Self.attention, Self.newChat, .toggleSidebar, .sidebarTrackingSeparator,
         Self.chatPicture, .flexibleSpace, .inspectorTrackingSeparator, Self.refresh, .flexibleSpace, Self.details]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        item.autovalidates = false
        switch identifier {
        case Self.account:
            item.label = "Account"
            item.isBordered = true
            item.action = #selector(showAccount)
        case Self.connecting:
            // Connection progress is a quiet spinner that disappears; only a setup failure gets a glyph.
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.startAnimation(nil)
            item.view = spinner
            item.label = "Connecting"
            self.spinner = spinner
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
        case Self.chatPicture:
            // Plain: the picture is the control, as the iPhone's header shows it.
            // Its fixed size, so the toolbar's tiling on each step of a resize never asks SwiftUI for one.
            let host = NSHostingView(rootView: MacPane { MacChatHeaderAvatar(model: self.model, window: self.state) })
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([host.widthAnchor.constraint(equalToConstant: 28), host.heightAnchor.constraint(equalToConstant: 28)])
            item.view = host
            item.label = "Chat Details"
            item.isBordered = false
            item.isNavigational = true
        case Self.refresh:
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.label = "Refresh"
            item.isBordered = true
            item.action = #selector(refresh)
        case Self.details:
            item.label = "Chat Details"
            item.toolTip = "Show or hide the chat's details (⌥⌘I)"
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Chat Details")
            item.isBordered = true
            item.action = #selector(toggleDetails)
        default:
            return nil
        }
        items[identifier] = item
        return item
    }

    /// The items' state, again whenever what it reads changes.
    private func update() {
        let signedIn = !model.accountID.isEmpty
        let connecting = model.isSettlingConnection || model.isCatchingUp
        if let item = items[Self.account] {
            item.toolTip = signedIn ? model.accountID : "Sign in"
            let picture = (account: model.accountID, image: model.avatars[model.accountID])
            if accountPicture?.account != picture.account || accountPicture?.image !== picture.image {
                accountPicture = picture
                item.image = Self.render(ChatAvatar(key: picture.account, name: Self.initial(of: picture.account), image: picture.image, size: 22),
                                         label: "Account")
            }
        }
        items[Self.connecting]?.isHidden = !connecting
        items[Self.connecting]?.label = model.isCatchingUp ? "Catching up" : "Connecting"
        spinner?.setAccessibilityLabel(model.isCatchingUp ? "Catching up" : "Connecting")
        if connecting { spinner?.startAnimation(nil) } else { spinner?.stopAnimation(nil) }
        items[Self.attention]?.isHidden = connecting || !model.connectionNeedsAttention
        items[Self.newChat]?.isEnabled = signedIn
        items[Self.chatPicture]?.isHidden = state.selection == nil
        items[Self.details]?.isHidden = state.selection == nil
        let page = state.inspectorShown && state.selection != nil ? state.inspectorPath.last : nil
        switch page {
        case .encryption: items[Self.refresh]?.toolTip = "Refresh devices"
        case .groupDetails: items[Self.refresh]?.toolTip = "Refresh group"
        default: break
        }
        items[Self.refresh]?.isHidden = refreshRoute(page) == nil
        items[Self.refresh]?.isEnabled = model.session.isReady
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

    /// The inspector's page asks the server again: its devices, or the group's members and devices.
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

    /// A SwiftUI picture as the item's image, kept in colour.
    private static func render(_ view: some View, label: String) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }
}

/// The open chat's picture in the toolbar, before its name; a click opens the details.
private struct MacChatHeaderAvatar: View {
    let model: AppModel
    let window: MacWindowState

    var body: some View {
        if let chatID = window.selection {
            Button { window.inspectorShown = true } label: {
                ChatAvatar(key: chatID, name: model.chatName(for: chatID),
                           image: model.avatar(for: chatID), isGroup: model.isGroup(chatID), size: 28)
            }
            .buttonStyle(.plain)
            .help("Show the chat's details")
            .accessibilityLabel("Chat Details")
            .task(id: "\(chatID)|\(model.session.isReady)") { await model.loadAvatar(for: chatID) }
        }
    }
}

/// Opens the Settings scene from AppKit, as its menu item does.
@MainActor enum MacSettingsOpening {
    static func open() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
