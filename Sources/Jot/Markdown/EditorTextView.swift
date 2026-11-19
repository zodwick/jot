import AppKit
import UniformTypeIdentifiers

/// The editor. Owns caret behaviour around hidden Markdown, list editing
/// (Return / Tab / Backspace), formatting commands, and file paste/drop.
final class EditorTextView: NSTextView {
    weak var styler: MarkdownStyler?

    private var ns: NSString { textStorage?.mutableString ?? "" }
    private var length: Int { textStorage?.length ?? 0 }

    // MARK: Hidden-run helpers

    private func isHidden(_ i: Int) -> Bool {
        guard let s = textStorage, i >= 0, i < s.length else { return false }
        return s.attribute(.jotHidden, at: i, effectiveRange: nil) != nil
    }

    /// The block prefix ("\t- ", "# ", "> ") covering index i, if any.
    private func prefixRange(at i: Int) -> NSRange? {
        guard let s = textStorage, i >= 0, i < s.length else { return nil }
        var r = NSRange()
        guard s.attribute(.jotPrefix, at: i, longestEffectiveRange: &r, in: ns.lineRange(for: NSRange(location: i, length: 0))) != nil else { return nil }
        return r
    }

    /// Never leave the caret inside a block prefix: snap it to where the content starts.
    private func snapped(_ loc: Int) -> Int {
        if let p = prefixRange(at: loc), loc < NSMaxRange(p) { return NSMaxRange(p) }
        return loc
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if ranges.count == 1, let r = ranges.first?.rangeValue, r.length == 0 {
            let s = snapped(r.location)
            if s != r.location { ranges = [NSValue(range: NSRange(location: s, length: 0))] }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        setNeedsCaretUpdate()
    }

    // MARK: Text-height cursor
    //
    // NSTextView sizes its cursor to the whole line, so next to an inline image
    // it grows to the image's height. Since macOS 14 it no longer calls
    // drawInsertionPoint(in:color:turnedOn:), so that can't be overridden
    // (STTextView: FB9713415). Like STTextView, we hide the built-in cursor and
    // place the system's own NSTextInsertionIndicator ourselves, sized to the
    // font and sitting on the text baseline. Same look, blink and accent colour.

    private lazy var caret: NSTextInsertionIndicator = {
        let indicator = NSTextInsertionIndicator(frame: .zero)
        indicator.displayMode = .hidden
        addSubview(indicator)
        return indicator
    }()
    private var caretUpdatePending = false

    override var shouldDrawInsertionPoint: Bool { false }

    func setNeedsCaretUpdate() {
        guard !caretUpdatePending else { return }
        caretUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            self?.caretUpdatePending = false
            self?.updateCaret()
        }
    }

    private func updateCaret() {
        let sel = selectedRange()
        let active = window?.isKeyWindow == true && window?.firstResponder === self && sel.length == 0
        guard active, let rect = caretRect(at: sel.location) else {
            caret.displayMode = .hidden
            return
        }
        caret.frame = rect
        caret.displayMode = .automatic
    }

    /// Insertion rect for `loc` in view coordinates: the x NSTextView would use,
    /// but only as tall as the text's font, on the line's baseline.
    func caretRect(at loc: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, let s = textStorage else { return nil }
        let font = caretFont(at: loc)
        var x: CGFloat
        var baseline: CGFloat
        var lineTop: CGFloat
        var lineBottom: CGFloat

        let afterLastNewline = s.length == 0 || (loc == s.length && ns.character(at: loc - 1) == 10)
        if afterLastNewline {
            // Empty page or empty last line: the "extra" line fragment.
            let extra = lm.extraLineFragmentRect
            let indent = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
            x = extra.minX + tc.lineFragmentPadding + indent
            lineTop = extra.minY
            lineBottom = extra.maxY
            baseline = extra.minY + ceil(font.ascender)
        } else {
            var count = 0
            let zero = NSRange(location: loc, length: 0)
            guard let rects = lm.rectArray(forCharacterRange: zero, withinSelectedCharacterRange: zero, in: tc, rectCount: &count),
                  count > 0 else { return nil }
            let r = rects[0]
            x = r.minX
            var lineGlyphs = NSRange()
            let g = lm.glyphIndex(for: NSPoint(x: r.minX, y: r.midY), in: tc)
            let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &lineGlyphs)
            lineTop = line.minY
            lineBottom = line.maxY
            baseline = line.minY + lm.location(forGlyphAt: lineGlyphs.location).y
        }

        let height = ceil(font.ascender - font.descender)
        let top = max(lineTop, baseline - ceil(font.ascender))
        let h = max(2, min(height, lineBottom - top))
        let origin = textContainerOrigin
        return NSRect(x: (x + origin.x - 1).rounded(), y: (top + origin.y).rounded(), width: 2, height: h.rounded())
    }

    /// The font the cursor should match: the character before it on the same
    /// line, else the one after it, else what you'd type next.
    private func caretFont(at loc: Int) -> NSFont {
        let fallback = (typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 15)
        guard let s = textStorage, s.length > 0 else { return fallback }
        func textFont(_ i: Int) -> NSFont? {
            guard i >= 0, i < s.length else { return nil }
            let c = ns.character(at: i)
            if c == 10 || c == 13 || s.attribute(.attachment, at: i, effectiveRange: nil) != nil { return nil }
            return s.attribute(.font, at: i, effectiveRange: nil) as? NSFont
        }
        return textFont(loc - 1) ?? textFont(loc) ?? fallback
    }

    override func didChangeText() {
        super.didChangeText()
        setNeedsCaretUpdate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsCaretUpdate()
    }

    override func becomeFirstResponder() -> Bool {
        defer { setNeedsCaretUpdate() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { setNeedsCaretUpdate() }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: window)
        }
        setNeedsCaretUpdate()
    }

    @objc private func windowKeyChanged() { setNeedsCaretUpdate() }

    // MARK: Arrow keys skip invisible characters

    override func moveLeft(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0 else { return super.moveLeft(sender) }
        var c = sel.location - 1
        while c >= 0, isHidden(c) { c -= 1 }
        guard c >= 0 else { return }
        var t = ns.rangeOfComposedCharacterSequence(at: c).location
        if let p = prefixRange(at: t), t < NSMaxRange(p) {
            // Stepping left out of a list item / heading goes to the previous line's end.
            guard p.location > 0 else { return }
            t = p.location - 1
        }
        setSelectedRange(NSRange(location: t, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func moveRight(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, sel.location < length else { return super.moveRight(sender) }
        var c = sel.location
        while c < length, isHidden(c) { c += 1 }
        guard c < length else { setSelectedRange(NSRange(location: length, length: 0)); return }
        let t = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: c))
        setSelectedRange(NSRange(location: snapped(t), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func moveBackward(_ sender: Any?) { moveLeft(sender) }
    override func moveForward(_ sender: Any?) { moveRight(sender) }

    // MARK: Deleting

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0 else { return super.deleteBackward(sender) }
        let p = sel.location

        // At the start of a list item / heading / quote: drop (or outdent) the prefix.
        if let pre = prefixRange(at: p - 1), NSMaxRange(pre) == p {
            removePrefix(pre)
            return
        }
        // Hidden markers right before the caret: delete the visible character before them,
        // so you never silently eat half of a "**" pair.
        if isHidden(p - 1) {
            var c = p - 1
            while c >= 0, isHidden(c) { c -= 1 }
            guard c >= 0 else { return }
            if let pre = prefixRange(at: c), NSMaxRange(pre) == c + 1 { removePrefix(pre); return }
            replace(ns.rangeOfComposedCharacterSequence(at: c), with: "")
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, sel.location < length else { return super.deleteForward(sender) }
        var c = sel.location
        while c < length, isHidden(c) { c += 1 }
        guard c < length else { return }
        // Joining with a following list item/heading: take its prefix with the newline.
        if ns.character(at: c) == 10, c + 1 < length, let pre = prefixRange(at: c + 1), pre.location == c + 1 {
            replace(NSRange(location: c, length: NSMaxRange(pre) - c), with: "", caret: sel.location)
            return
        }
        if c != sel.location {
            replace(ns.rangeOfComposedCharacterSequence(at: c), with: "", caret: sel.location)
            return
        }
        super.deleteForward(sender)
    }

    /// Backspace at the start of a prefixed line: outdent if nested, else remove the prefix.
    private func removePrefix(_ pre: NSRange) {
        let lineText = ns.substring(with: pre)
        if let list = ListPrefix.parse(lineText + "x"), list.level > 0 {
            outdent(lineStartingAt: pre.location)
            return
        }
        replace(pre, with: "", caret: pre.location)
    }

    // MARK: Return / Tab

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = contentOfLine(lineRange)

        // Inside a code block: keep indentation; auto-close a fresh ``` fence.
        if let s = textStorage, lineRange.location < s.length,
           let region = s.attribute(.jotCodeRegion, at: lineRange.location, effectiveRange: nil) as? CodeRegion {
            let isFence = s.attribute(.jotFence, at: lineRange.location, effectiveRange: nil) != nil
            if isFence, !region.closed, sel.location == lineRange.location + (lineText as NSString).length {
                insertText("\n\n```", replacementRange: sel)
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return
            }
            let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
            insertText("\n" + indent, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 1 + (indent as NSString).length, length: 0))
            return
        }

        if sel.length == 0, let list = ListPrefix.parse(lineText) {
            let contentStart = lineRange.location + list.length
            let content = (lineText as NSString).substring(from: min(list.length, (lineText as NSString).length))
            if content.trimmingCharacters(in: .whitespaces).isEmpty, sel.location >= contentStart {
                // Return on an empty item ends the list (or steps out one level).
                if list.level > 0 { outdent(lineStartingAt: lineRange.location) }
                else { replace(NSRange(location: lineRange.location, length: (lineText as NSString).length), with: "", caret: lineRange.location) }
                return
            }
            if sel.location >= contentStart {
                insertText("\n" + list.continuation(), replacementRange: sel)
                return
            }
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let lines = ns.paragraphRange(for: sel)
        let multiLine = ns.substring(with: sel).contains("\n")
        if multiLine || ListPrefix.parse(contentOfLine(lines)) != nil, !inCodeBlock(sel.location) {
            indentLines(sender)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) { outdentLines(sender) }

    /// "[] " or "[ ] " typed at the start of a line becomes a checklist item.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let str = string as? String, str == " ", replacementRange.location == NSNotFound || replacementRange.length == 0 {
            let sel = selectedRange()
            let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let before = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            if (trimmed == "[]" || trimmed == "[ ]"), !inCodeBlock(sel.location) {
                let indent = String(before.prefix { $0 == " " || $0 == "\t" })
                replace(NSRange(location: line.location, length: sel.location - line.location), with: indent + "- [ ] ")
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: Line commands (Format menu)

    @objc func indentLines(_ sender: Any?) { transformLines { "\t" + $0 } }

    @objc func outdentLines(_ sender: Any?) {
        transformLines { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix(4).prefix { $0 == " " }.count
            return String(line.dropFirst(spaces))
        }
    }

    private func outdent(lineStartingAt loc: Int) {
        setSelectedRange(NSRange(location: loc, length: 0))
        let line = ns.lineRange(for: NSRange(location: loc, length: 0))
        let before = selectedRange().location
        outdentLines(nil)
        _ = before
        // keep caret at the content start of the outdented line
        let newLine = ns.lineRange(for: NSRange(location: min(line.location, length), length: 0))
        if let p = ListPrefix.parse(contentOfLine(newLine)) {
            setSelectedRange(NSRange(location: newLine.location + p.length, length: 0))
        }
    }

    @objc func toggleBulletList(_ sender: Any?) { toggleList { _ in "- " } match: { $0.checkbox == nil && !$0.isNumbered } }
    @objc func toggleNumberedList(_ sender: Any?) { toggleList { "\($0 + 1). " } match: { $0.isNumbered } }
    @objc func toggleChecklist(_ sender: Any?) { toggleList { _ in "- [ ] " } match: { $0.checkbox != nil } }

    private func toggleList(_ marker: @escaping (Int) -> String, match: @escaping (ListPrefix) -> Bool) {
        let paragraph = ns.paragraphRange(for: selectedRange())
        let lines = ns.substring(with: paragraph).components(separatedBy: "\n").filter { !$0.isEmpty }
        let allMatch = !lines.isEmpty && lines.allSatisfy { ListPrefix.parse($0).map(match) ?? false }
        var index = 0
        transformLines { line in
            let parsed = ListPrefix.parse(line)
            let indent = parsed?.indent ?? String(line.prefix { $0 == " " || $0 == "\t" })
            let body = parsed.map { String((line as NSString).substring(from: $0.length)) }
                ?? String(line.dropFirst(indent.count))
            if allMatch { return indent + body }
            defer { index += 1 }
            return indent + marker(index) + body
        }
    }

    @objc func toggleBold(_ sender: Any?) { toggleWrap("**") }
    @objc func toggleItalic(_ sender: Any?) { toggleWrap("_") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleWrap("`") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleWrap("~~") }

    private func toggleWrap(_ m: String) {
        let sel = selectedRange()
        let ml = (m as NSString).length
        if sel.length == 0 {
            insertText(m + m, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + ml, length: 0))
            return
        }
        let text = ns.substring(with: sel)
        let before = NSRange(location: sel.location - ml, length: ml)
        let after = NSRange(location: NSMaxRange(sel), length: ml)
        if before.location >= 0, NSMaxRange(after) <= length,
           ns.substring(with: before) == m, ns.substring(with: after) == m {
            replace(NSRange(location: before.location, length: sel.length + 2 * ml), with: text)
            setSelectedRange(NSRange(location: before.location, length: sel.length))
        } else if text.hasPrefix(m), text.hasSuffix(m), (text as NSString).length >= 2 * ml {
            let inner = (text as NSString).substring(with: NSRange(location: ml, length: (text as NSString).length - 2 * ml))
            replace(sel, with: inner)
            setSelectedRange(NSRange(location: sel.location, length: (inner as NSString).length))
        } else {
            replace(sel, with: m + text + m)
            setSelectedRange(NSRange(location: sel.location + ml, length: sel.length))
        }
    }

    /// Applies `f` to every line touched by the selection as one undoable edit.
    private func transformLines(_ f: (String) -> String) {
        let sel = selectedRange()
        let paragraph = ns.paragraphRange(for: sel)
        let original = ns.substring(with: paragraph)
        var lines = original.components(separatedBy: "\n")
        let trailingNewline = original.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        if lines.isEmpty { lines = [""] }
        let joined = lines.map(f).joined(separator: "\n") + (trailingNewline ? "\n" : "")
        guard joined != original else { return }
        replace(paragraph, with: joined)
        let delta = (joined as NSString).length - (original as NSString).length
        if sel.length == 0, lines.count == 1 {
            setSelectedRange(NSRange(location: max(paragraph.location, sel.location + delta), length: 0))
        } else {
            setSelectedRange(NSRange(location: paragraph.location, length: (joined as NSString).length - (trailingNewline ? 1 : 0)))
        }
    }

    // MARK: Checkbox clicks, opening attachments

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        if let lm = layoutManager as? MarkdownLayoutManager, let box = lm.checkbox(at: containerPoint) {
            let current = ns.substring(with: box)
            replace(box, with: current.hasPrefix("[ ]") ? "[x]" : "[ ]", caret: selectedRange().location)
            return
        }
        if event.clickCount == 2, let url = attachmentURL(at: containerPoint) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func attachmentURL(at point: NSPoint) -> URL? {
        guard let lm = layoutManager, let tc = textContainer, let s = textStorage, s.length > 0 else { return nil }
        let g = lm.glyphIndex(for: point, in: tc, fractionOfDistanceThroughGlyph: nil)
        guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).contains(point) else { return nil }
        let ci = lm.characterIndexForGlyph(at: g)
        guard ci < s.length, let att = s.attribute(.attachment, at: ci, effectiveRange: nil) as? NSTextAttachment else { return nil }
        return (att.attachmentCell as? ImageAttachmentCell)?.url ?? (att.attachmentCell as? FileChipCell)?.url
    }

    // MARK: Copy: always Markdown

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let s = textStorage else { return false }
        let text = selectedRanges.map { Atoms.encode(s, range: $0.rangeValue) }.joined(separator: "\n")
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(text, forType: .string)
    }

    // MARK: Paste / drop: files become attachments, text becomes Markdown

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.fileURL] + Self.imageTypes + [.string] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.fileURL] + Self.imageTypes + [.string] }

    override func preferredPasteboardType(from availableTypes: [NSPasteboard.PasteboardType],
                                          restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?) -> NSPasteboard.PasteboardType? {
        if availableTypes.contains(.fileURL) { return .fileURL }
        // Text wins over image data (apps often put a picture of copied text on the pasteboard too).
        if availableTypes.contains(.string) { return .string }
        return Self.imageTypes.first { availableTypes.contains($0) }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let styler else { return super.readSelection(from: pboard, type: type) }
        switch type {
        case .fileURL:
            let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let markdown = urls.compactMap { url -> String? in
                guard let rel = Store.shared.importFile(url) else { return nil }
                return Atoms.markdown(forImported: rel, originalName: url.lastPathComponent)
            }
            guard !markdown.isEmpty else { return false }
            insertAtoms(markdown, styler: styler)
            return true
        case .png, .tiff:
            guard var data = pboard.data(forType: type) else { return false }
            if type == .tiff, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { data = png }
            guard let rel = Store.shared.importData(data, ext: "png") else { return false }
            insertAtoms([Atoms.markdown(forImported: rel, originalName: "image.png")], styler: styler)
            return true
        default:
            guard let text = pboard.string(forType: .string) else { return false }
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            replace(selectedRange(), with: Atoms.decode(normalized, styler: styler))
            return true
        }
    }

    /// Images go on their own line; file chips sit inline.
    private func insertAtoms(_ markdown: [String], styler: MarkdownStyler) {
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let anyImage = markdown.contains { $0.hasPrefix("!") }
        var text = markdown.joined(separator: anyImage ? "\n" : " ")
        if anyImage {
            if sel.location > line.location { text = "\n" + text }
            if NSMaxRange(sel) < length, ns.character(at: NSMaxRange(sel)) != 10 { text += "\n" }
        }
        replace(sel, with: Atoms.decode(text, styler: styler))
    }

    // MARK: Editing primitives (all undoable)

    private func replace(_ range: NSRange, with str: String, caret: Int? = nil) {
        replace(range, with: NSAttributedString(string: str, attributes: typingAttributes), caret: caret)
    }

    private func replace(_ range: NSRange, with str: NSAttributedString, caret: Int? = nil) {
        guard let s = textStorage, shouldChangeText(in: range, replacementString: str.string) else { return }
        s.replaceCharacters(in: range, with: str)
        didChangeText()
        setSelectedRange(NSRange(location: caret ?? range.location + str.length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    private func contentOfLine(_ lineRange: NSRange) -> String {
        var s = ns.substring(with: lineRange)
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    private func inCodeBlock(_ loc: Int) -> Bool {
        guard let s = textStorage, s.length > 0 else { return false }
        let i = min(loc, s.length - 1)
        return s.attribute(.jotCodeRegion, at: i, effectiveRange: nil) != nil
    }
}
