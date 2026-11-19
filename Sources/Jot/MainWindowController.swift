import AppKit

/// The one window: Liquid Glass background, an endless text view on top.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let glass = NSGlassEffectView()
    private let scrim = ScrimView(frame: .zero)
    private let scrollView = NSScrollView()
    private(set) var textView: EditorTextView!
    private var editor: MarkdownEditorStack!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Jot"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 280, height: 200)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        super.init(window: window)
        window.delegate = self

        buildContent()
        loadPage()
        applyPreferences()

        window.setFrameAutosaveName("JotMainWindow")
        if !window.setFrameUsingName("JotMainWindow") { window.center() }

        NotificationCenter.default.addObserver(self, selector: #selector(applyPreferences),
                                               name: .jotPreferencesChanged, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applyPreferences),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let window else { return }

        editor = MarkdownEditorStack()
        textView = editor.textView
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Leave room for the traffic lights; the text scrolls under the transparent titlebar.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 30, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: -30, left: 0, bottom: 0, right: 0)

        // Glass → container(scrim + scroll view). Only contentView is guaranteed
        // to sit inside the glass, so both live in one container.
        let container = NSView()
        scrim.autoresizingMask = [.width, .height]
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrim)
        container.addSubview(scrollView)
        glass.contentView = container
        glass.cornerRadius = 16
        window.contentView = glass
        scrim.frame = container.bounds
        scrollView.frame = container.bounds
    }

    private func loadPage() {
        editor.load(markdown: Store.shared.load())
        // Start with the caret at the end: the most likely place to keep writing.
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func flush() {
        guard editor != nil else { return }
        Store.shared.flush(editor.markdown())
    }

    // MARK: Preferences

    private var wasFloating: Bool?

    @objc private func applyPreferences() {
        guard let window else { return }
        let floating = Preferences.floatOnTop
        window.level = floating ? .floating : .normal
        window.collectionBehavior = floating
            ? [.fullScreenAuxiliary, .canJoinAllSpaces]
            : [.fullScreenAuxiliary, .moveToActiveSpace]
        // Fade only when floating is switched; slider drags and launch apply instantly.
        let floatingChanged = wasFloating != nil && wasFloating != floating
        wasFloating = floating
        GlassAppearance.apply(glass: glass, scrim: scrim, density: Preferences.glassDensity,
                              floating: floating, animated: floatingChanged)
        editor.setBaseFontSize(Preferences.fontSize)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        Store.shared.scheduleSave { [weak self] in self?.editor.markdown() ?? "" }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        flush()
        sender.orderOut(nil)
        return false
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(textView)
    }
}
