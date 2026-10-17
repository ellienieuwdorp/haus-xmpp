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
    /// The window's content is never shorter, so a column laid out at half of it is AppKit's minimum-size pass
    /// (`MacProbeShield`).
    static let windowMinHeight = 480.0

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
        // The width by a constraint on the window, not this frame: SwiftUI counts a frame's minimum into the split view's
        // main column, and in a window near it, opening the inspector widened that column past the window for the whole
        // animation, then rewrapped the whole timeline at its final width in one long pass.
        .frame(minHeight: Self.windowMinHeight)
        .background(MacWindowMinimum(width: windowMinWidth))
        .alert("Something needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        #if DEBUG
        .modifier(MacDebugPresentation(model: model, window: window))
        .modifier(MacScenePhaseLog(window: "main"))
        .background(MacUnobtrusive.Anchor())
        #endif
    }

    private var split: some View {
        NavigationSplitView {
            MacProbeShield { MacChatList(model: model, window: window) }
                .navigationSplitViewColumnWidth(min: Self.sidebarWidth.min, ideal: Self.sidebarWidth.ideal, max: Self.sidebarWidth.max)
        } detail: {
            MacProbeShield { detail }
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
            .background(MacColumnPresence { present in
                inspectorOnScreen = present
                // A pushed page stays alive in the hidden column, and its toolbar items (Refresh) would move into the
                // conversation's toolbar; the inspector opens on the chat's details again.
                if !present, !showsInspector { window.inspectorPath.removeAll() }
            })
        }
        .id(model.accountID)
        // Its own view: it reads the chat list, which this view's body must not, or every new message would rebuild the
        // open conversation.
        .background { MacChatCommandsSource(model: model, window: window) }
        // A Block or Report from the sidebar's menu or the Chat menu; here, so it shows with the sidebar collapsed too.
        .blockConfirmation(model: model, request: $window.blockRequest)
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
            MacConversationView(model: model, chatID: chatID)
                .id(chatID)
                // Both bounds, so the frame takes the width it is offered and asks for none: the window's minimum
                // keeps the conversation readable (`conversationMinWidth`), and a wide banner or tray cannot raise it.
                .frame(minWidth: 0, maxWidth: .infinity)
                // Here, outside the chat's identity, so a switch updates these items instead of replacing them.
                .toolbar {
                    // The contact's picture before the name, as the iPhone's header shows it; a click opens the details.
                    ToolbarItem(placement: .navigation) {
                        MacChatHeaderAvatar(model: model, chatID: chatID) { window.inspectorShown = true }
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) {
                        Button { window.inspectorShown.toggle() } label: { Label("Chat Details", systemImage: "info.circle") }
                            .help("Show or hide the chat's details (⌥⌘I)")
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

/// The open chat's picture in the toolbar, before its name.
private struct MacChatHeaderAvatar: View {
    let model: AppModel
    let chatID: String
    let showDetails: () -> Void

    var body: some View {
        Button(action: showDetails) {
            ChatAvatar(key: chatID, name: AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title),
                       image: model.avatars[chatID], isGroup: model.isGroup(chatID), size: 28)
        }
        .buttonStyle(.plain)
        .help("Show the chat's details")
        .accessibilityLabel("Chat Details")
        .task(id: "\(chatID)|\(model.session.isReady)") { await model.loadAvatar(for: chatID) }
    }
}

/// Publishes the Chat menu's commands for the main window.
private struct MacChatCommandsSource: View {
    let model: AppModel
    let window: MacWindowState

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .focusedSceneValue(\.macChatCommands, MacChatCommands(model: model, window: window))
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

/// Holds the window's content at least `width` wide, with a required constraint of its own on the window's content
/// view. AppKit keeps a window's content at its constraints' minimum, live and programmatic resizes alike, and widens the
/// window when the minimum grows past it, as it does for the minimum SwiftUI reports from the content.
struct MacWindowMinimum: NSViewRepresentable {
    let width: Double

    final class View: NSView {
        var width: Double = 0 { didSet { if width != oldValue { apply() } } }
        private var constraint: NSLayoutConstraint?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { constraint?.isActive = false; constraint = nil }
        }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }

        private func apply() {
            guard let content = window?.contentView else { return }
            if constraint?.firstItem !== content {
                constraint?.isActive = false
                constraint = content.widthAnchor.constraint(greaterThanOrEqualToConstant: width)
                constraint?.isActive = true
            }
            constraint?.constant = width
        }
    }

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) { view.width = width }
}

/// Keeps a split view column's content at its last real size through AppKit's minimum-size passes. With the inspector's
/// split view in the window, open or not, every change of the window's size first lays the window's main column out at
/// its minimum (about 320 by 170 points), then at its real size, and SwiftUI lays the sidebar and the conversation out at
/// that minimum as well: a step of a live resize laid the timeline out three times more, each time rewrapping every
/// bubble on screen. No real layout is shorter than the window's minimum height, so a much shorter one is such a pass;
/// the content keeps the size it has, and the real size follows in the same pass before anything is drawn.
struct MacProbeShield<Content: View>: View {
    @ViewBuilder let content: Content
    /// Outside the layout's cache, which SwiftUI rebuilds whenever the content changes.
    @State private var last = LastSize()

    final class LastSize { var size: CGSize? }

    var body: some View { ShieldLayout(last: last) { content } }

    private struct ShieldLayout: Layout {
        let last: LastSize

        /// Measuring is unchanged, so the column's minimum, and the window's, stay what the content asks for.
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            subviews.first?.sizeThatFits(proposal) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var size = bounds.size
            if size.height < MacRootView.windowMinHeight / 2, let kept = last.size { size = kept } else { last.size = size }
            for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(size)) }
        }
    }
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
