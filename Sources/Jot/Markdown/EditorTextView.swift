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

    /// A line whose text is entirely hidden ("---" drawn as a rule, a bare ``` fence),
    /// as its content range without the newline. Only its end is a real caret spot.
    private func hiddenLine(at i: Int) -> NSRange? {
        guard let s = textStorage, i >= 0, i <= s.length, s.length > 0 else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(i, s.length), length: 0))
        var content = line
        if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
        guard content.length > 0, i <= NSMaxRange(content),
              s.attribute(.jotRule, at: content.location, effectiveRange: nil) != nil
                || s.attribute(.jotFence, at: content.location, effectiveRange: nil) != nil else { return nil }
        var hidden = NSRange()
        guard s.attribute(.jotHidden, at: content.location, longestEffectiveRange: &hidden, in: content) != nil,
              NSMaxRange(hidden) >= NSMaxRange(content) else { return nil }
        return content
    }

    /// Where a line's content starts (after "- ", "# ", "> " …).
    private func contentStart(ofLineAt loc: Int) -> Int {
        let line = ns.lineRange(for: NSRange(location: min(loc, length), length: 0))
        if let p = prefixRange(at: line.location), p.location == line.location { return NSMaxRange(p) }
        return line.location
    }

    /// Never leave the caret inside a block prefix or a hidden line.
    private func snapped(_ loc: Int) -> Int {
        if let p = prefixRange(at: loc), loc < NSMaxRange(p) { return NSMaxRange(p) }
        if let h = hiddenLine(at: loc) { return NSMaxRange(h) }
        return loc
    }

    /// Selections never cut a prefix in half: an end inside one moves past it, and a
    /// start inside one moves to the content (or, for a multi-line selection, to the
    /// line start so whole lines are taken). Otherwise Shift-⌘-← or a double-click on
    /// a bullet would select the invisible "- " and deleting would eat the bullet.
    private func snapped(_ r: NSRange) -> NSRange {
        guard r.length > 0 else { return NSRange(location: snapped(r.location), length: 0) }
        var start = r.location, end = NSMaxRange(r)
        if let p = prefixRange(at: end), end > p.location, end < NSMaxRange(p) { end = NSMaxRange(p) }
        if let p = prefixRange(at: start), start < NSMaxRange(p) {
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            let lineEnd = NSMaxRange(line) - (NSMaxRange(line) > line.location && ns.character(at: NSMaxRange(line) - 1) == 10 ? 1 : 0)
            start = end <= lineEnd ? NSMaxRange(p) : line.location
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if ranges.count == 1, let r = ranges.first?.rangeValue {
            let s = snapped(r)
            if s != r { ranges = [NSValue(range: s)] }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        resetTypingAttributesOnEmptyLine()
        setNeedsCaretUpdate()
    }

    /// On an empty line, NSTextView borrows the typing attributes of the newline
    /// before it (a heading's font, a quote's indent, code styling), so the caret
    /// and first letter start out wrong. An empty line is plain body text.
    private func resetTypingAttributesOnEmptyLine() {
        // Never type with the styler's private attributes (hidden, fence, prefix…)
        // picked up from the character before the caret.
        let leaked: [NSAttributedString.Key] = [.jotHidden, .jotPrefix, .jotMarker, .jotRule, .jotFence, .jotInlineCode,
                                                .jotQuote, .jotSource, .attachment, .link, .kern, .strikethroughStyle]
        if leaked.contains(where: { typingAttributes[$0] != nil }) {
            var attrs = typingAttributes
            for k in leaked { attrs[k] = nil }
            if (attrs[.foregroundColor] as? NSColor) == NSColor.clear { attrs[.foregroundColor] = NSColor.labelColor }
            typingAttributes = attrs
        }
        guard let styler, selectedRanges.count == 1 else { return }
        let sel = selectedRange()
        guard sel.length == 0, !inCodeBlock(sel.location) else { return }
        let atLineStart = sel.location == 0 || ns.character(at: sel.location - 1) == 10
        let atLineEnd = sel.location == length || ns.character(at: sel.location) == 10
        if atLineStart, atLineEnd { typingAttributes = styler.typingAttributes }
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
            // Empty page or empty last line: the "extra" line fragment. With
            // non-contiguous layout it's only an estimate until the end is laid out.
            if s.length > 0 { lm.ensureLayout(forCharacterRange: NSRange(location: s.length - 1, length: 1)) }
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

    // MARK: Deferred styling

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        if replacementStrings != nil, let s = textStorage {
            for r in affectedRanges { styler?.simplifyBeforeReplacing(s, r.rangeValue) }
        }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    /// Characters on screen, or nil outside a scroll view (nothing to prioritise).
    func visibleCharacterRange() -> NSRange? {
        guard let lm = layoutManager, let tc = textContainer, enclosingScrollView != nil,
              let s = textStorage, s.length > 0 else { return nil }
        var rect = visibleRect
        guard !rect.isEmpty else { return nil }
        rect.origin.x -= textContainerOrigin.x
        rect.origin.y -= textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        return lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// Text scrolled into view before its deferred restyle ran gets styled right
    /// away, before the scroll is drawn. (Styling it from viewWillDraw is too
    /// late for that frame: the restyle resizes the view mid-draw. That stays
    /// only as a backstop.)
    @objc private func clipBoundsChanged() {
        // Not from inside an edit (an edit's own resize scrolls the clip view):
        // the storage can't take another edit then; the edit styles its own surroundings.
        guard textStorage?.editedMask.isEmpty != false else { return }
        styler?.styleVisiblePending()
    }

    override func viewWillDraw() {
        styler?.styleVisiblePending()
        super.viewWillDraw()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = superview as? NSClipView {
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
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

    /// One visible step back from `p`: skips hidden markers, steps out of a prefix to
    /// the previous line's end, and over hidden lines. nil = nowhere to go.
    private func backwardTarget(from p: Int) -> Int? {
        guard p > 0 else { return nil }
        var c = p - 1
        while c >= 0, isHidden(c) { c -= 1 }
        guard c >= 0 else { return nil }
        var t = ns.rangeOfComposedCharacterSequence(at: c).location
        if let pre = prefixRange(at: t), t < NSMaxRange(pre) {
            // Stepping back out of a list item / heading goes to the previous line's end.
            guard pre.location > 0 else { return nil }
            t = pre.location - 1
        }
        while let h = hiddenLine(at: t) {
            guard h.location > 0 else { return nil }
            t = h.location - 1
        }
        return t
    }

    /// One visible step forward from `p`.
    private func forwardTarget(from p: Int) -> Int? {
        guard p < length else { return nil }
        var c = p
        while c < length, isHidden(c) { c += 1 }
        guard c < length else { return length }
        var t = snapped(NSMaxRange(ns.rangeOfComposedCharacterSequence(at: c)))
        // Landing on a collapsed ``` / --- line: carry on to the line after it.
        while let h = hiddenLine(at: t), NSMaxRange(h) < length, t == NSMaxRange(h), t != p {
            let next = NSMaxRange(h) + 1
            let after = snapped(next)
            if hiddenLine(at: after) == nil || after == t { t = after; break }
            t = after
        }
        return t
    }

    /// Right-to-left lines keep AppKit's own visual arrow handling.
    private func lineIsRightToLeft(_ loc: Int) -> Bool {
        let line = ns.lineRange(for: NSRange(location: min(loc, length), length: 0))
        let text = ns.substring(with: line)
        return text.unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFDFF).contains($0.value) || (0xFE70...0xFEFF).contains($0.value) }
    }

    private func moveCaret(to t: Int?) {
        guard let t else { return }
        // Downstream: at a soft wrap the caret belongs to the start of the next line.
        setSelectedRange(NSRange(location: t, length: 0), affinity: .downstream, stillSelecting: false)
        scrollRangeToVisible(selectedRange())
    }

    override func moveBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0 else { return super.moveBackward(sender) }
        moveCaret(to: backwardTarget(from: sel.location))
    }

    override func moveForward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0 else { return super.moveForward(sender) }
        moveCaret(to: forwardTarget(from: sel.location))
    }

    override func moveLeft(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, !lineIsRightToLeft(sel.location) else { return super.moveLeft(sender) }
        moveCaret(to: backwardTarget(from: sel.location))
    }

    override func moveRight(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, !lineIsRightToLeft(sel.location) else { return super.moveRight(sender) }
        moveCaret(to: forwardTarget(from: sel.location))
    }

    // Shift-arrows: the moving end steps over hidden characters too, so every press
    // changes what you see selected. The anchor is the end that didn't move last time.
    private var extendState: (anchor: Int, head: Int, sel: NSRange)?

    private func extendSelection(backward: Bool) {
        let sel = selectedRange()
        var anchor: Int, head: Int
        if let st = extendState, st.sel == sel {
            anchor = st.anchor; head = st.head
        } else {
            anchor = backward ? NSMaxRange(sel) : sel.location
            head = backward ? sel.location : NSMaxRange(sel)
            if sel.length == 0 {
                // Start from the visible edge: Shift-← after "**bold**" selects "d", not "d**".
                if backward { while anchor > 0, isInlineMarker(anchor - 1) { anchor -= 1 } }
                else { while anchor < length, isInlineMarker(anchor) { anchor += 1 } }
            }
        }
        guard let t = backward ? backwardTarget(from: head) : forwardTarget(from: head) else { return }
        head = t
        setSelectedRange(NSRange(location: min(anchor, head), length: abs(anchor - head)), affinity: .downstream, stillSelecting: false)
        extendState = (anchor, head, selectedRange())
        scrollRangeToVisible(NSRange(location: min(head, length), length: 0))
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        lineIsRightToLeft(selectedRange().location) ? super.moveLeftAndModifySelection(sender) : extendSelection(backward: true)
    }
    override func moveRightAndModifySelection(_ sender: Any?) {
        lineIsRightToLeft(selectedRange().location) ? super.moveRightAndModifySelection(sender) : extendSelection(backward: false)
    }
    override func moveBackwardAndModifySelection(_ sender: Any?) { extendSelection(backward: true) }
    override func moveForwardAndModifySelection(_ sender: Any?) { extendSelection(backward: false) }

    // MARK: Deleting

    /// A hidden inline marker ("**", "`", "](url)"), as opposed to a block prefix or a fence/rule.
    private func isInlineMarker(_ i: Int) -> Bool {
        guard isHidden(i), prefixRange(at: i) == nil, hiddenLine(at: i) == nil else { return false }
        return textStorage?.attribute(.jotFence, at: i, effectiveRange: nil) == nil
    }

    /// Deleting a selection keeps inline markers balanced: markers at its edges stay,
    /// and a closing marker inside takes its opening one with it.
    private func deleteSelectionKeepingMarkers(_ sel: NSRange) -> Bool {
        var a = sel.location, b = NSMaxRange(sel)
        while a < b, isInlineMarker(a) { a += 1 }
        while b > a, isInlineMarker(b - 1) { b -= 1 }
        guard a != sel.location || b != NSMaxRange(sel) || (sel.location..<NSMaxRange(sel)).contains(where: isInlineMarker) else { return false }
        if a == b { setSelectedRange(NSRange(location: a, length: 0)); return true }
        deleteSpan(NSRange(location: a, length: b - a), caret: nil)
        return true
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0, selectedRanges.count == 1, deleteSelectionKeepingMarkers(sel) { return }
        guard sel.length == 0, sel.location > 0 else { return super.deleteBackward(sender) }
        let p = sel.location

        // At the start of a list item / heading / quote: drop (or outdent) the prefix.
        if let pre = prefixRange(at: p - 1), NSMaxRange(pre) == p {
            removePrefix(pre)
            return
        }
        // At the end of a "---" or ``` line: un-hide it by deleting one character ("--").
        if let h = hiddenLine(at: p - 1), p == NSMaxRange(h) {
            replace(NSRange(location: p - 1, length: 1), with: "")
            return
        }
        // At the start of the line after one: a rule goes away; a fence stays (deleting
        // it would turn everything below into code), the caret just steps over it.
        if ns.character(at: p - 1) == 10, p >= 2, let h = hiddenLine(at: p - 2) {
            if textStorage?.attribute(.jotRule, at: h.location, effectiveRange: nil) != nil {
                replace(NSRange(location: h.location, length: p - h.location), with: "")
            } else {
                moveCaret(to: backwardTarget(from: p))
            }
            return
        }
        // Hidden markers right before the caret: delete the visible character before them,
        // so you never silently eat half of a "**" pair.
        if isHidden(p - 1) {
            var c = p - 1
            while c >= 0, isHidden(c) {
                // Walked back into a heading / quote prefix ("# **b**", caret before b).
                if let pre = prefixRange(at: c) { removePrefix(pre); return }
                c -= 1
            }
            guard c >= 0 else { return }
            deleteVisible(ns.rangeOfComposedCharacterSequence(at: c))
            return
        }
        let target = ns.rangeOfComposedCharacterSequence(at: p - 1)
        if isHidden(target.location - 1), isHidden(NSMaxRange(target)) {
            deleteVisible(target)   // last letter of a span: take its markers too
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0, selectedRanges.count == 1, deleteSelectionKeepingMarkers(sel) { return }
        guard sel.length == 0, sel.location < length else { return super.deleteForward(sender) }
        var c = sel.location
        while c < length, isHidden(c) { c += 1 }
        guard c < length else { return }
        // Joining with a following list item/heading: take its prefix with the newline.
        if ns.character(at: c) == 10, c + 1 < length, let pre = prefixRange(at: c + 1), pre.location == c + 1 {
            replace(NSRange(location: c, length: NSMaxRange(pre) - c), with: "", caret: sel.location)
            return
        }
        // Joining with a following rule removes the rule; a fence is left alone.
        if ns.character(at: c) == 10, let h = hiddenLine(at: c + 1), h.location == c + 1 {
            if textStorage?.attribute(.jotRule, at: h.location, effectiveRange: nil) != nil {
                replace(NSRange(location: c, length: NSMaxRange(h) - c), with: "", caret: sel.location)
            }
            return
        }
        let target = ns.rangeOfComposedCharacterSequence(at: c)
        if c != sel.location || (isHidden(c - 1) && isHidden(NSMaxRange(target))) {
            deleteVisible(target, caret: sel.location)
            return
        }
        super.deleteForward(sender)
    }

    /// Deletes visible text; if that empties a span ("**b**" → "****"), the span's
    /// markers go too instead of turning into literal asterisks.
    private func deleteVisible(_ r: NSRange, caret: Int? = nil) {
        let end = NSMaxRange(r)
        if isHidden(r.location - 1), isHidden(end) {
            var a = r.location
            while a > 0, isHidden(a - 1), prefixRange(at: a - 1) == nil { a -= 1 }
            var b = end
            while b < length, isHidden(b) { b += 1 }
            let left = ns.substring(with: NSRange(location: a, length: r.location - a))
            let right = ns.substring(with: NSRange(location: end, length: b - end))
            for m in ["**", "__", "~~", "`", "*", "_"] where left.hasSuffix(m) && right.hasPrefix(m) {
                let ml = (m as NSString).length
                replace(NSRange(location: r.location - ml, length: r.length + 2 * ml), with: "", caret: r.location - ml)
                return
            }
            if left.hasSuffix("["), right.hasPrefix("](") {   // a link whose text is gone
                replace(NSRange(location: r.location - 1, length: b - r.location + 1), with: "", caret: r.location - 1)
                return
            }
        }
        replace(r, with: "", caret: caret)
    }

    // ⌥⌫ / ⌘⌫ / ⌥⌦: let AppKit pick the range, then keep it out of prefixes and
    // never leave half a marker pair behind.
    override func deleteWordBackward(_ sender: Any?) {
        deleteSpanBackward({ super.moveWordBackwardAndModifySelection(nil) }, fallback: { super.deleteWordBackward(sender) })
    }
    override func deleteToBeginningOfLine(_ sender: Any?) {
        deleteSpanBackward({ super.moveToBeginningOfLineAndModifySelection(nil) }, fallback: { super.deleteToBeginningOfLine(sender) })
    }
    override func deleteToBeginningOfParagraph(_ sender: Any?) {
        deleteSpanBackward({ super.moveToBeginningOfParagraphAndModifySelection(nil) }, fallback: { super.deleteToBeginningOfParagraph(sender) })
    }
    override func deleteWordForward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0 else { return super.deleteWordForward(sender) }
        super.moveWordForwardAndModifySelection(nil)
        let r = selectedRange()
        guard r.location == sel.location, r.length > 0 else { setSelectedRange(sel); return }
        var start = r.location
        while start < NSMaxRange(r), isHidden(start) { start += 1 }   // keep leading markers
        deleteSpan(NSRange(location: start, length: NSMaxRange(r) - start), caret: sel.location)
    }

    private func deleteSpanBackward(_ extend: () -> Void, fallback: () -> Void) {
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0 else { return fallback() }
        let p = sel.location
        // At the content start of an item / heading: same as Backspace.
        if p == contentStart(ofLineAt: p), let pre = prefixRange(at: p - 1), NSMaxRange(pre) == p {
            removePrefix(pre)
            return
        }
        extend()   // selection snapping keeps the start out of this line's prefix
        let r = selectedRange()
        guard NSMaxRange(r) == p, r.length > 0 else { setSelectedRange(sel); return }
        var end = NSMaxRange(r)
        while end > r.location, isHidden(end - 1) { end -= 1 }   // keep trailing markers
        deleteSpan(NSRange(location: r.location, length: end - r.location), caret: nil)
    }

    /// Deletes a word/line range. If it swallowed a closing marker, also take the
    /// opening run just before it, so "x **bold** |" ⌥⌫ doesn't leave "x **".
    private func deleteSpan(_ r: NSRange, caret: Int?) {
        guard r.length > 0 else { setSelectedRange(NSRange(location: caret ?? r.location, length: 0)); return }
        var r = r
        var hiddenInside = false
        for i in r.location..<NSMaxRange(r) where isInlineMarker(i) { hiddenInside = true; break }
        if hiddenInside {
            var a = r.location
            while a > 0, isInlineMarker(a - 1) { a -= 1 }
            r = NSRange(location: a, length: NSMaxRange(r) - a)
        }
        deleteVisible(r, caret: caret.map { min($0, r.location) })
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

        // Return over a selection inside a list item: drop the selection, then continue the list.
        if sel.length > 0, ListPrefix.parse(lineText) != nil, NSMaxRange(sel) <= NSMaxRange(lineRange) {
            replace(sel, with: "")
            return insertNewline(sender)
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
                let insertion = "\n" + list.continuation()
                if list.isNumbered, let n = Int(list.marker.dropLast()),
                   let (tail, renumbered) = renumberedItems(after: NSMaxRange(lineRange), level: list.level, startingAt: n + 2) {
                    // One edit: the new item plus the renumbered items below it.
                    let rest = ns.substring(with: NSRange(location: sel.location, length: tail.location - sel.location))
                    replace(NSRange(location: sel.location, length: NSMaxRange(tail) - sel.location),
                            with: insertion + rest + renumbered, caret: sel.location + (insertion as NSString).length)
                } else {
                    insertText(insertion, replacementRange: sel)
                }
                return
            }
        }

        // Return at the start of a heading / quote pushes it down instead of
        // splitting its (invisible) "# " off onto an empty line.
        if sel.length == 0, let pre = prefixRange(at: lineRange.location), pre.location == lineRange.location,
           sel.location == NSMaxRange(pre), sel.location < lineRange.location + (lineText as NSString).length {
            replace(NSRange(location: lineRange.location, length: 0), with: "\n", caret: sel.location + 1)
            return
        }
        super.insertNewline(sender)
    }

    /// Numbered items below `loc` at `level`, renumbered from `first`. Returns the
    /// range they cover and the new text, or nil if nothing changes.
    private func renumberedItems(after loc: Int, level: Int, startingAt first: Int) -> (NSRange, String)? {
        var n = first
        var next = loc
        var end = loc
        var changed = false
        var out = ""
        while next < length {
            let line = ns.lineRange(for: NSRange(location: next, length: 0))
            let text = ns.substring(with: line)
            guard let p = ListPrefix.parse(contentOfLine(line)) else { break }
            if p.level > level { out += text; next = NSMaxRange(line); end = next; continue }   // nested items keep theirs
            guard p.level == level, p.isNumbered, let delim = p.marker.last else { break }
            let want = "\(n)\(delim)"
            if want != p.marker { changed = true }
            out += p.indent + want + (text as NSString).substring(from: (p.indent as NSString).length + (p.marker as NSString).length)
            n += 1
            next = NSMaxRange(line)
            end = next
        }
        guard changed else { return nil }
        return (NSRange(location: loc, length: end - loc), out)
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let lines = ns.paragraphRange(for: sel)
        let multiLine = ns.substring(with: sel).contains("\n")
        if multiLine || (ListPrefix.parse(contentOfLine(lines)) != nil && !inCodeBlock(sel.location)) {
            indentLines(sender)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) { outdentLines(sender) }

    /// "[] " or "[ ] " typed at the start of a line becomes a checklist item.
    /// ⌃↩ / ⌥↩ insert U+2028; Jot's text is plain lines, so that's just a newline.
    override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let str = string as? String, Fences.normalizeNewlines(str) != str {
            return insertText(Fences.normalizeNewlines(str), replacementRange: replacementRange)
        }
        if let str = string as? String, str == " ", replacementRange.location == NSNotFound || replacementRange.length == 0 {
            let sel = selectedRange()
            let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let before = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
            var trimmed = before.trimmingCharacters(in: .whitespaces)
            // "- " is invisible, so "[] " typed into an empty bullet counts too.
            for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) { trimmed = String(trimmed.dropFirst(2)); break }
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
        var sel = selectedRange()
        let ml = (m as NSString).length
        if sel.length == 0 {
            // Caret inside an existing span: unwrap it.
            if let span = enclosingSpan(m, at: sel.location) {
                let mk = span.marker
                let inner = NSRange(location: span.range.location + mk, length: span.range.length - 2 * mk)
                replace(span.range, with: ns.substring(with: inner), caret: sel.location - mk)
                return
            }
            insertText(m + m, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + ml, length: 0))
            return
        }
        // "**word **" or "**line\n**" don't render: wrap the trimmed text, line by line.
        let raw = ns.substring(with: sel) as NSString
        var a = 0, b = raw.length
        while a < b, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(raw.character(at: a)) ?? " ") { a += 1 }
        while b > a, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(raw.character(at: b - 1)) ?? " ") { b -= 1 }
        guard b > a else { return }
        sel = NSRange(location: sel.location + a, length: b - a)
        if ns.substring(with: sel).contains("\n") {
            wrapLines(in: sel, m)
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

    /// The `m` span (bold, italic, code, strike) around `loc` on its line, if any.
    private func enclosingSpan(_ m: String, at loc: Int) -> (range: NSRange, marker: Int)? {
        let re: NSRegularExpression
        switch m {
        case "**": re = MarkdownPatterns.bold
        case "`": re = MarkdownPatterns.inlineCode
        case "~~": re = MarkdownPatterns.strike
        default: re = MarkdownPatterns.italic
        }
        let line = ns.lineRange(for: NSRange(location: loc, length: 0))
        let text = ns.substring(with: line)
        for match in re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let r = NSRange(location: match.range.location + line.location, length: match.range.length)
            let mk = m == "`" ? 1 : match.range(at: 1).length
            if loc >= r.location + mk, loc <= NSMaxRange(r) - mk { return (r, mk) }
        }
        return nil
    }

    /// Wraps (or unwraps, if all already are) each line's content in `m`.
    private func wrapLines(in sel: NSRange, _ m: String) {
        let paragraph = ns.paragraphRange(for: sel)
        var lines = ns.substring(with: paragraph).components(separatedBy: "\n")
        let trailing = lines.last == ""
        if trailing { lines.removeLast() }
        func split(_ line: String) -> (prefix: String, body: String, tail: String) {
            let pre = ListPrefix.parse(line)?.length
                ?? MarkdownPatterns.heading.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))?.range.length
                ?? MarkdownPatterns.quote.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))?.range.length ?? 0
            let rest = (line as NSString).substring(from: pre)
            let body = rest.trimmingCharacters(in: .whitespaces)
            let lead = (line as NSString).substring(to: pre) + String(rest.prefix { $0 == " " || $0 == "\t" })
            return (lead, body, String(rest.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()))
        }
        let parts = lines.map(split)
        let allWrapped = parts.allSatisfy { $0.body.isEmpty || ($0.body.hasPrefix(m) && $0.body.hasSuffix(m) && $0.body.count >= 2 * m.count) }
        let out = parts.map { p -> String in
            guard !p.body.isEmpty else { return p.prefix + p.tail }
            let body = allWrapped ? String(p.body.dropFirst(m.count).dropLast(m.count)) : m + p.body + m
            return p.prefix + body + p.tail
        }.joined(separator: "\n") + (trailing ? "\n" : "")
        replace(paragraph, with: out)
        setSelectedRange(NSRange(location: paragraph.location, length: (out as NSString).length - (trailing ? 1 : 0)))
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
            let normalized = Fences.normalizeNewlines(text)
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
            if sel.location > contentStart(ofLineAt: line.location) { text = "\n" + text }
            if NSMaxRange(sel) < length, ns.character(at: NSMaxRange(sel)) != 10 { text += "\n" }
        }
        replace(sel, with: Atoms.decode(text, styler: styler))
    }

    // MARK: Editing primitives (all undoable)

    /// Replaces only the part that actually changes (so undo restores a small
    /// range and the caret lands where the change was, not at the line's end).
    private func replace(_ range: NSRange, with str: String, caret: Int? = nil) {
        let caret = caret ?? range.location + (str as NSString).length
        // Compared as UTF-16 (fast on a whole page), then widened to whole
        // composed characters so an edit never splits an emoji or accent.
        let oldNS = ns.substring(with: range) as NSString, newNS = str as NSString
        let old = Array((oldNS as String).utf16), new = Array(str.utf16)
        func splits(_ s: NSString, _ i: Int) -> Bool { i > 0 && i < s.length && s.rangeOfComposedCharacterSequence(at: i).location != i }
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        while splits(oldNS, head) || splits(newNS, head) { head -= 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        while tail > 0, splits(oldNS, old.count - tail) || splits(newNS, new.count - tail) { tail -= 1 }
        let r = NSRange(location: range.location + head, length: old.count - tail - head)
        let newMid = newNS.substring(with: NSRange(location: head, length: new.count - tail - head))
        guard r.length > 0 || !newMid.isEmpty else {
            setSelectedRange(NSRange(location: caret, length: 0))
            return
        }
        replace(r, with: NSAttributedString(string: newMid, attributes: typingAttributes), caret: caret)
    }

    private func replace(_ range: NSRange, with str: NSAttributedString, caret: Int? = nil) {
        guard let s = textStorage else { return }
        // One storage edit: preparing a big range for undo (shouldChangeText)
        // then costs no layout pass of its own.
        s.beginEditing()
        guard shouldChangeText(in: range, replacementString: str.string) else { s.endEditing(); return }
        s.replaceCharacters(in: range, with: str)
        s.endEditing()
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
        if loc >= s.length {
            // Empty last line: only inside a block that was never closed.
            guard ns.character(at: s.length - 1) == 10 else { return s.attribute(.jotCodeRegion, at: s.length - 1, effectiveRange: nil) != nil }
            return (s.attribute(.jotCodeRegion, at: s.length - 1, effectiveRange: nil) as? CodeRegion)?.closed == false
        }
        return s.attribute(.jotCodeRegion, at: loc, effectiveRange: nil) != nil
    }
}
