import SwiftUI

/// The main window. Like the iPhone's root, the upgrade and key-recovery screens replace everything until they are
/// settled; otherwise a split view: chats in the sidebar, the open chat as the detail, and its details in an inspector.
struct MacRootView: View {
    @Bindable var model: AppModel
    @Bindable var window: MacWindowState
    /// The inspector's column is on screen: from when it starts to open until it has finished closing.
    @State private var inspectorOnScreen = false

    /// The columns' widths. The split view reads each column's minimum from its content, and the window's minimum must
    /// leave room for all of them: when the window is narrower than the columns' minimums add up to, AppKit's split
    /// view moves the columns, SwiftUI reports new minimums from inside that constraint pass, and AppKit aborts after
    /// laying the window out again more times than it has views. So every minimum here is a constant, none follows
    /// content or another column's width.
    private static let sidebarWidth = (min: 260.0, ideal: 320.0, max: 360.0)
    /// Fixed: the minimum the window needs with the inspector open never changes while it resizes.
    private static let inspectorWidth = 320.0
    /// The narrowest the conversation gets: the composer, a bubble and its reactions still fit. The window's minimum
    /// keeps it, not the conversation's own: the conversation's column extends under the sidebar and the inspector,
    /// its minimum includes both their widths, and the split view adds the inspector's width once more for the
    /// inspector itself. Asking for nothing there keeps the columns' sum what the window really needs.
    private static let conversationMinWidth = 320.0

    private var showsInspector: Bool { window.inspectorShown && window.selection != nil }

    private var windowMinWidth: Double {
        // Until the inspector has gone, not from the moment it is asked to close: its column still counts while it
        // animates away.
        max(720, Self.conversationMinWidth + Self.sidebarWidth.max + (showsInspector || inspectorOnScreen ? Self.inspectorWidth : 0))
    }

    var body: some View {
        Group {
            if model.transferState == .none, model.upgradeState == .none, model.keyRecovery == nil {
                split
            } else if model.transferState != .none {
                TransferBlockingView(model: model)
            } else if model.upgradeState != .none {
                UpgradeBlockingView(model: model)
            } else {
                KeyRecoveryView(model: model)
            }
        }
        .frame(minWidth: windowMinWidth, minHeight: 480)
        .alert("Something needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        #if DEBUG
        .modifier(MacDebugPresentation(window: window))
        .modifier(MacScenePhaseLog(window: "main"))
        .background(MacUnobtrusive.Anchor())
        #endif
    }

    private var split: some View {
        NavigationSplitView {
            MacChatList(model: model, window: window)
                .navigationSplitViewColumnWidth(min: Self.sidebarWidth.min, ideal: Self.sidebarWidth.ideal, max: Self.sidebarWidth.max)
        } detail: {
            detail
        }
        // On the split view, not inside its detail column: a navigation stack in an inspector placed in the detail
        // pushed its pages into the detail column's own navigation, replacing the conversation.
        .inspector(isPresented: Binding(get: { showsInspector }, set: { window.inspectorShown = $0 })) {
            Group {
                if let chatID = window.selection {
                    MacChatInspector(model: model, chatID: chatID, path: $window.inspectorPath).id(chatID)
                }
            }
            .inspectorColumnWidth(Self.inspectorWidth)
            .background(MacColumnPresence { inspectorOnScreen = $0 })
        }
        .id(model.accountID)
        .onChange(of: model.accountID) { _, _ in window.selection = nil; window.inspectorShown = false }
        .onChange(of: window.selection) { previous, selection in
            if let previous { model.closeChat(previous) }
            // Pages of the chat just left; a route that also chose the new chat has already pushed its own.
            window.inspectorPath.removeAll { !Self.route($0, isFor: selection) }
        }
        // The window closed (the app keeps running): nothing is on screen to read.
        .onDisappear { if let chatID = window.selection { model.closeChat(chatID) } }
        .onChange(of: model.notificationRoute, initial: true) { _, route in
            guard let route else { return }
            model.consumeNotificationRoute(route.id)
            guard route.accountID == model.accountID else { return }
            window.showingAccount = false
            window.selection = route.chatID
        }
        .onChange(of: model.requestedRoute) { _, route in
            guard let route else { return }
            model.requestedRoute = nil
            switch route {
            case .chat(let chatID): window.selection = chatID
            case .details(let chatID), .encryption(let chatID), .groupDetails(let chatID):
                window.selection = chatID
                window.inspectorShown = true
                window.inspectorPath = route == .details(chatID) ? [] : [route]
            }
        }
        .onChange(of: model.signInRequested) { _, requested in
            guard requested else { return }
            model.signInRequested = false
            window.showingAccount = true
        }
        .alert("Transfer restored", isPresented: $model.transferRestored) {
            Button("OK") {}
        } message: {
            Text("Your chats are here. To finish the move, open Haus XMPP on the other device and choose Delete Data.")
        }
        .sheet(isPresented: $window.showingAccount) {
            SignInView(model: model)
                .frame(minWidth: 440, idealWidth: 460, minHeight: 460, idealHeight: 520)
                .themedRoot()
        }
        .sheet(isPresented: $window.showingRestore) { RestoreTransferView(model: model).themedRoot() }
        .sheet(isPresented: $window.showingNewChat) {
            MacNewChatSheet(model: model) { chatID in
                window.showingNewChat = false
                window.selection = chatID
            }
            .themedRoot()
        }
        .sheet(isPresented: $window.reviewingOwnDevices) {
            OwnDeviceReviewSheet(model: model)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 640)
                .themedRoot()
        }
    }

    private static func route(_ route: ChatRoute, isFor chatID: String?) -> Bool {
        switch route {
        case .chat(let id), .details(let id), .encryption(let id), .groupDetails(let id): id == chatID
        }
    }

    @ViewBuilder private var detail: some View {
        if let chatID = window.selection {
            MacConversationView(model: model, chatID: chatID) { window.inspectorShown = true }
                .id(chatID)
                // Both bounds, so the frame takes the width it is offered and asks for none: the window's minimum
                // keeps the conversation readable (`conversationMinWidth`), and a wide banner or tray cannot raise it.
                .frame(minWidth: 0, maxWidth: .infinity)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { window.inspectorShown.toggle() } label: { Label("Chat Details", systemImage: "info.circle") }
                            .help("Show or hide the chat's details")
                    }
                }
        } else {
            ContentUnavailableView {
                Label(model.chats.isEmpty ? "No conversations yet" : "No chat selected", systemImage: "bubble.left.and.bubble.right")
            } description: {
                if model.hasLoadedChats, model.chats.isEmpty {
                    Text(model.accountID.isEmpty
                         ? "Sign in to your XMPP account, or explore sample conversations."
                         : "Start a conversation with New Chat (⌘N).")
                } else {
                    Text("Choose a chat in the sidebar.")
                }
            } actions: {
                if model.hasLoadedChats, model.chats.isEmpty, model.accountID.isEmpty {
                    Button("Sign In…") { window.showingAccount = true }
                        .buttonStyle(.borderedProminent)
                    Button("Explore Sample Conversations") { Task { await model.loadDemo() } }
                    if model.canRestoreTransfer { Button("Restore from a Transfer…") { window.showingRestore = true } }
                }
            }
        }
    }
}

/// Chat details in the inspector, with the pages it links to (devices and encryption, group details) pushed inside it.
struct MacChatInspector: View {
    @Bindable var model: AppModel
    let chatID: String
    @Binding var path: [ChatRoute]

    var body: some View {
        NavigationStack(path: $path) {
            ChatDetailsView(model: model, chatID: chatID)
                .navigationDestination(for: ChatRoute.self) { route in
                    switch route {
                    case .encryption(let chatID): EncryptionDetailsView(model: model, chatID: chatID).macInspectorPage("Devices & Encryption")
                    case .groupDetails(let room): GroupDetailsView(model: model, room: room).macInspectorPage("Group details")
                    // The conversation is already the detail column; details never link back to it.
                    case .chat, .details: EmptyView()
                    }
                }
        }
        .labelStyle(.listRow)
    }
}

/// A page pushed inside the inspector: its title and a Back button at the top of the inspector. The system's Back
/// button would sit in the window toolbar's leading area, beside the conversation's title, where it reads as the
/// conversation's own.
struct MacInspectorPage: ViewModifier {
    let title: String
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden()
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless)
                        .help("Back")
                    Text(title).font(.headline).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
    }
}

extension View {
    func macInspectorPage(_ title: String) -> some View { modifier(MacInspectorPage(title: title)) }
}

/// Reports whether the column it sits in is on screen. A split view hides a collapsed column only once it has
/// finished animating closed, and SwiftUI keeps an inspector's content (and its `onDisappear`) alive while hidden.
struct MacColumnPresence: NSViewRepresentable {
    let changed: (Bool) -> Void

    final class View: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var reported: Bool?

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func viewDidHide() { super.viewDidHide(); report() }
        override func viewDidUnhide() { super.viewDidUnhide(); report() }

        private func report() {
            let present = window != nil && !isHiddenOrHasHiddenAncestor
            guard present != reported else { return }
            reported = present
            // Called from AppKit's layout of the split view: SwiftUI's state changes after it.
            let changed = changed
            DispatchQueue.main.async { changed(present) }
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: View, context: Context) { view.changed = changed }
}
