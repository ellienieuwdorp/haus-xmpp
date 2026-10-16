import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the composer's text view asks of the composer: the keys that act on the message rather than the text, and the
/// files or images pasted or dropped into it.
@MainActor struct MacComposerKeyActions {
    /// Return, Enter or Command-Return with no marked text.
    var send: () -> Void
    /// Up-arrow in an empty draft; true when it started an edit.
    var editLast: () -> Bool
    /// Esc with no marked text; true when it cancelled a reply or an edit.
    var cancel: () -> Bool
    /// True when the composer took them; false leaves the paste or drop to the text view.
    var attach: (MacComposerAttachments) -> Bool
}

/// Files or an image handed to the composer by a paste or a drop.
enum MacComposerAttachments {
    case files([URL])
    /// An image on the pasteboard with no file behind it (a screenshot, an image copied from a page).
    case image(Data, UTType)

    /// File URLs win (Finder also puts the file's name as text and its icon as an image); text wins over an image
    /// rendition of itself (Pages, Notes and browsers put both); an image without text is an image. nil pastes text.
    static func read(from pasteboard: NSPasteboard) -> MacComposerAttachments? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        let types = pasteboard.types ?? []
        if types.contains(.string) || types.contains(.rtf) || types.contains(.html) { return nil }
        for (type, uti) in imageTypes where types.contains(type) {
            if let data = pasteboard.data(forType: type) { return .image(data, uti) }
        }
        return nil
    }

    static let imageTypes: [(NSPasteboard.PasteboardType, UTType)] = [
        (.png, .png), (.tiff, .tiff), (NSPasteboard.PasteboardType(UTType.jpeg.identifier), .jpeg), (NSPasteboard.PasteboardType(UTType.heic.identifier), .heic),
    ]
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL] + imageTypes.map(\.0)
}

/// The composer's text field: a plain-text `NSTextView` in an `NSScrollView`, sized to its text up to `maxLines` and
/// scrolling inside itself beyond that. Spelling, the system's autocorrection and text replacement, Writing Tools and
/// undo are the text view's own. The draft goes to `state` on every change and comes back only when the composer
/// replaces it (a send, an edit filling it in, a failed send putting it back).
struct MacComposerTextField: NSViewRepresentable {
    @Bindable var state: MacComposerState
    let placeholder: String
    let actions: MacComposerKeyActions
    /// Changes whenever the text view should take keyboard focus.
    let focusRequests: Int

    static let font = NSFont.preferredFont(forTextStyle: .body)
    static let maxLines = 8
    /// Space above and below the text, so one line sits in the middle of the field's 44 pt minimum.
    static let verticalInset: CGFloat = 13
    static let lineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: font)

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MacComposerTextView(usingTextLayoutManager: true)
        textView.configure()
        textView.delegate = context.coordinator
        textView.actions = actions
        textView.string = state.draft
        context.coordinator.textView = textView
        context.coordinator.focusRequests = focusRequests
        #if DEBUG
        MacComposerTour.textView = textView
        #endif
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MacComposerTextView else { return }
        textView.actions = actions
        textView.setAccessibilityPlaceholderValue(placeholder)
        // The composer replaced the draft; typing never gets here with a different string. Never while an input method
        // composes: replacing the text would drop its marked text.
        let draft = state.draft
        if textView.string != draft, !textView.hasMarkedText() {
            textView.string = draft
            textView.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0))
            // Undo must not reach back across a send into text that is no longer in the field.
            context.coordinator.undo.removeAllActions()
        }
        if context.coordinator.focusRequests != focusRequests {
            context.coordinator.focusRequests = focusRequests
            textView.focus()
        }
    }

    /// One line high when empty, then the text's height up to `maxLines`. Measured from the text alone: resizing the
    /// text view here would invalidate the layout SwiftUI is in the middle of.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        let text = (scrollView.documentView as? NSTextView)?.string ?? state.draft
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? scrollView.frame.width
        let height = min(max(Self.textHeight(text, width: width), Self.lineHeight), Self.lineHeight * CGFloat(Self.maxLines))
        return CGSize(width: proposal.width ?? width, height: height + 2 * Self.verticalInset)
    }

    /// The laid-out height of `text` at `width`, counting the empty line after a trailing newline.
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return lineHeight }
        let bounds = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height) + (text.last?.isNewline == true ? lineHeight : 0)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let state: MacComposerState
        var focusRequests = 0
        /// The composer's own undo stack, not the window's: a draft's history stays with its chat, and a send clears it.
        let undo = UndoManager()
        weak var textView: MacComposerTextView?

        init(state: MacComposerState) {
            self.state = state
            super.init()
            // Undo and redo outside the Edit menu's path change the text without `textDidChange`; read it back after
            // either, so the draft never goes stale.
            for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoChanged), name: name, object: undo)
            }
        }

        @objc private func undoChanged() {
            guard let textView, state.draft != textView.string else { return }
            state.draft = textView.string
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            state.draft = textView.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }
}

final class MacComposerTextView: NSTextView {
    var actions: MacComposerKeyActions?
    /// The key event being interpreted, for its modifiers.
    private var keyEvent: NSEvent?

    func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        font = MacComposerTextField.font
        textColor = .labelColor
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        textContainerInset = NSSize(width: 0, height: MacComposerTextField.verticalInset)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        // Spelling marks always; corrections, text replacement and smart punctuation follow the system's settings
        // (Keyboard > Text Input), which a new text view already reads.
        isContinuousSpellCheckingEnabled = true
        writingToolsBehavior = .complete
        setAccessibilityLabel("Message")
        setAccessibilityHelp("Return sends. Shift-Return starts a new line.")
        setAccessibilityIdentifier("messageComposer")
    }

    /// Makes the text view the window's first responder once it is in a window.
    func focus() {
        guard let window else { wantsFocus = true; return }
        wantsFocus = false
        if window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    /// Asked for before it was in a window (a chat opening).
    private var wantsFocus = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, wantsFocus else { return }
        // After SwiftUI has put the rest of the window's views in place, so nothing it adds later takes focus back.
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        keyEvent = event
        defer { keyEvent = nil }
        // Command-Return has no key binding, so it would never reach `doCommand`. Not while an input method composes.
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.contains(.command), !hasMarkedText() {
            actions?.send()
            return
        }
        super.keyDown(with: event)
    }

    /// Runs after the input method has seen the key, so a Return or Esc that confirms or cancels a composition never
    /// gets here; `hasMarkedText()` covers text marked without one.
    override func doCommand(by selector: Selector) {
        if handleCommand(selector, modifiers: (keyEvent ?? NSApp.currentEvent)?.modifierFlags ?? []) { return }
        super.doCommand(by: selector)
    }

    /// The composer's meaning of a key command; false leaves it to the text view.
    func handleCommand(_ selector: Selector, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            if hasMarkedText() { unmarkText(); return true }
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                actions?.send()
            }
            return true
        case #selector(moveUp(_:)):
            return string.isEmpty && !hasMarkedText() && actions?.editLast() == true
        case #selector(cancelOperation(_:)):
            return !hasMarkedText() && actions?.cancel() == true
        default:
            return false
        }
    }

    // MARK: Paste and drop

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        MacComposerAttachments.pasteboardTypes + super.readablePasteboardTypes
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let attachments = MacComposerAttachments.read(from: pasteboard), actions?.attach(attachments) == true { return true }
        // A file or image type was picked only because it is listed first here: paste what a plain text view would
        // have picked instead, such as the text an image came with.
        if MacComposerAttachments.pasteboardTypes.contains(type) {
            guard let plain = pasteboard.availableType(from: super.readablePasteboardTypes) else { return false }
            return super.readSelection(from: pasteboard, type: plain)
        }
        return super.readSelection(from: pasteboard, type: type)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        MacComposerAttachments.pasteboardTypes + super.acceptableDragTypes
    }

    /// Overriding `acceptableDragTypes` does not register them; without this a file drag is never routed here.
    override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        registerForDraggedTypes(acceptableDragTypes)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let attachments = MacComposerAttachments.read(from: sender.draggingPasteboard), actions?.attach(attachments) == true { return true }
        return super.performDragOperation(sender)
    }
}
