import AppKit

/// Builds an explicit TextKit 1 stack (storage → layout manager → container → view).
/// TextKit 1 is used on purpose: it's the only stack with a per-glyph hook for
/// hiding Markdown markers, and its document heights are exact (no scroll jumps).
final class MarkdownEditorStack {
    let styler = MarkdownStyler()
    let storage = NSTextStorage()
    private let stylingDelegate: MarkdownStylingDelegate
    let layoutManager = MarkdownLayoutManager()
    let container: NSTextContainer
    let textView: EditorTextView

    init() {
        stylingDelegate = MarkdownStylingDelegate(styler: styler)
        storage.delegate = stylingDelegate
        layoutManager.styler = styler
        storage.addLayoutManager(layoutManager)

        container = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: container)
        textView.styler = styler
        configure(textView)
    }

    private func configure(_ tv: EditorTextView) {
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 22, height: 8)

        tv.drawsBackground = false
        tv.isRichText = true          // attachments need it; pasteboard types are restricted in EditorTextView
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true

        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = true
        // These would rewrite Markdown syntax ("---" → "—", "`" → "‘").
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false

        tv.typingAttributes = styler.typingAttributes
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        // No text colour here: markers drawn in clear stay invisible when selected.
        tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
    }

    func load(markdown: String) {
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        storage.endEditing()
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: Atoms.decode(markdown, styler: styler))
        storage.endEditing()   // the styling delegate styles the whole page here
        textView.undoManager?.removeAllActions()
    }

    func markdown() -> String {
        Atoms.encode(storage, range: NSRange(location: 0, length: storage.length))
    }

    func setBaseFontSize(_ size: CGFloat) {
        guard size != styler.baseSize else { return }
        styler.baseSize = size
        storage.restyleAll(with: styler)
        textView.typingAttributes = styler.typingAttributes
    }
}
