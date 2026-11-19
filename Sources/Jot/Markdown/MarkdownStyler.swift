import AppKit

/// Turns Markdown text into display attributes, one paragraph at a time.
/// Only the edited paragraphs are restyled on each keystroke; code fences are
/// tracked with a cheap whole-document scan, and a new ``` restyles only the
/// lines that move into or out of a code block (big changes partly deferred).
final class MarkdownStyler {
    var baseSize: CGFloat = 15 { didSet { rebuild() } }

    private(set) var bodyFont = NSFont.systemFont(ofSize: 15)
    private(set) var monoFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    private(set) var indentStep: CGFloat = 24
    private var headingFonts: [NSFont] = []
    private var baseParagraph = NSParagraphStyle()
    private var codeParagraph = NSParagraphStyle()
    private var paragraphCache: [String: NSParagraphStyle] = [:]
    private var widthCache: [String: CGFloat] = [:]

    private struct Block {
        var range: NSRange
        var open: NSRange
        var close: NSRange?
        let token: CodeRegion
    }
    private var blocks: [Block] = []
    private var fenceLines: [NSRange] = []
    /// Substring being styled and its offset in the document, so regexes only
    /// ever see the edited paragraphs instead of a copy of the whole page.
    private var text = ""
    private var base = 0

    // MARK: Deferred styling
    //
    // Big changes (a fence opened near the top of a long page, a paste, load,
    // a font change) restyle only what's around the edit right away. The rest
    // is remembered in `pending` and styled in small chunks on the main queue,
    // what's on screen first. Invariant: every character outside `pending` is
    // styled exactly as a fresh load of the current text would style it.

    /// Characters whose styling is out of date. Shifts with every edit.
    private(set) var pending = IndexSet()
    /// What the current deferred pass styled (to settle AppKit's font fixing after it).
    private var styledSpan: NSRange?
    /// False only while the text certainly has no attachment (U+FFFC) characters,
    /// which spares restyling a search for them. Attachments only ever arrive in
    /// inserted text, and every insertion passes through `restyle`.
    private var mayHaveAttachments = false
    private weak var target: NSMutableAttributedString?
    private var pumpScheduled = false
    /// The editor's on-screen character range (nil when not in a scroll view).
    var visibleRange: (() -> NSRange?)?
    /// Up to this many characters are restyled synchronously; beyond that only
    /// `syncWindow` characters around the edit are, and the rest is deferred.
    static var syncLimit = 12_000
    static var syncWindow = 3_000
    /// Main-thread time one deferred chunk may take.
    static var chunkBudget: TimeInterval = 0.004

    init() { rebuild() }

    var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraph]
    }

    private var codeAttributes: [NSAttributedString.Key: Any] {
        [.font: monoFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: codeParagraph]
    }

    private func rebuild() {
        bodyFont = .systemFont(ofSize: baseSize)
        monoFont = .monospacedSystemFont(ofSize: (baseSize * 0.9).rounded(), weight: .regular)
        indentStep = (baseSize * 1.6).rounded()
        headingFonts = [
            .systemFont(ofSize: (baseSize * 1.6).rounded(), weight: .bold),
            .systemFont(ofSize: (baseSize * 1.32).rounded(), weight: .bold),
            .systemFont(ofSize: (baseSize * 1.14).rounded(), weight: .semibold),
            .systemFont(ofSize: baseSize, weight: .semibold),
        ]
        let p = NSMutableParagraphStyle()
        p.lineSpacing = (baseSize * 0.28).rounded()
        p.defaultTabInterval = indentStep
        p.tabStops = []
        baseParagraph = p.copy() as! NSParagraphStyle

        let c = p.mutableCopy() as! NSMutableParagraphStyle
        c.lineSpacing = 2
        c.firstLineHeadIndent = 12
        c.headIndent = 12
        c.tailIndent = -12
        c.defaultTabInterval = monoFont.maximumAdvancement.width * 4
        codeParagraph = c.copy() as! NSParagraphStyle

        paragraphCache = [:]
        widthCache = [:]
        traitCache = [:]
    }

    // MARK: Entry points (called from the text storage delegate)

    /// Restyles whatever an edit could have affected: the edited paragraphs, and
    /// any paragraph whose code-block membership the edit changed.
    func restyle(_ s: NSMutableAttributedString, edited: NSRange, delta: Int) {
        target = s
        let ns = s.mutableString
        var range = ns.paragraphRange(for: edited)
        // An edit ending in a newline (Return mid-line, a pasted line) made a new
        // paragraph out of the text after it; restyle that one too.
        if NSMaxRange(edited) == NSMaxRange(range), NSMaxRange(range) < ns.length {
            range = NSUnionRange(range, ns.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)))
        }
        let edit = Edit(start: range.location, oldEnd: NSMaxRange(range) - delta, newEnd: NSMaxRange(range))
        if !mayHaveAttachments, ns.range(of: "\u{FFFC}", options: .literal, range: range).location != NSNotFound {
            mayHaveAttachments = true
        }

        // Stale text moves with the edit; the edited paragraphs are restyled below.
        func shifted(_ set: IndexSet) -> IndexSet {
            var set = set
            if edit.oldEnd > edit.start { set.remove(integersIn: edit.start..<edit.oldEnd) }
            if delta != 0 { set.shift(startingAt: edit.oldEnd, by: delta) }
            set.remove(integersIn: ns.length..<max(ns.length, (set.last ?? 0) + 1))
            return set
        }
        let stale = shifted(pending)

        // Fences only need a full rescan when the edited lines had or have one;
        // otherwise the known fence lines just shift by the edit's length.
        let touchedOld = fenceLines.contains { $0.location <= edit.oldEnd && NSMaxRange($0) > edit.start }
        let hasNew = ns.range(of: "```", options: .literal, range: range).location != NSNotFound
        let fences = touchedOld || hasNew
            ? Fences.scan(ns)
            : fenceLines.map { $0.location >= edit.oldEnd ? NSRange(location: $0.location + delta, length: $0.length) : $0 }
        fenceLines = fences
        let old = blocks
        blocks = makeBlocks(fences, length: ns.length, reusing: old, edit: edit)

        // Lines outside the edit only need restyling where they changed role
        // (prose ↔ code, fence ↔ body, or which block they belong to).
        var need = flips(from: old, to: blocks, edit: edit)
        need.insert(integersIn: edit.start..<edit.newEnd)
        need.formUnion(stale)

        var now = need
        if need.count > Self.syncLimit {
            // Roles before the edit never change, so what's on screen is around
            // and below it: the edit's start, and its end (where the caret lands).
            let w = Self.syncWindow
            var window = IndexSet(integersIn: edit.start..<min(ns.length, edit.start + w))
            window.insert(integersIn: max(edit.start, edit.newEnd - w)..<min(ns.length, edit.newEnd + w))
            now = IndexSet()
            for r in need.intersection(window).rangeView {
                let para = ns.paragraphRange(for: NSRange(location: r.lowerBound, length: r.count))
                now.insert(integersIn: para.location..<NSMaxRange(para))
            }
        }
        pending = need.subtracting(now)
        // Deferred text is collapsed first, so styling the rest doesn't pay for
        // its attribute runs (see `collapse`).
        for r in pending.subtracting(stale).rangeView { collapse(s, NSRange(location: r.lowerBound, length: r.count)) }
        for r in now.rangeView { styleNow(s, NSRange(location: r.lowerBound, length: r.count), fix: true) }
        schedulePending()
    }

    func restyleAll(_ s: NSMutableAttributedString) {
        target = s
        let ns = s.mutableString
        fenceLines = Fences.scan(ns)
        blocks = makeBlocks(fenceLines, length: ns.length, reusing: [], edit: nil)
        mayHaveAttachments = ns.range(of: "\u{FFFC}", options: .literal).location != NSNotFound
        let all = NSRange(location: 0, length: ns.length)
        pending = IndexSet()
        if all.length <= Self.syncLimit {
            style(s, range: all)
            return
        }
        pending.insert(integersIn: 0..<all.length)
        collapse(s, all)
        schedulePending()
    }

    // MARK: Deferred passes

    /// Styles pending text for up to `budget` seconds, what's visible first.
    func stylePending(budget: TimeInterval, maxChunks: Int = .max) {
        guard let s = target, !pending.isEmpty else { return }
        let deadline = Date().addingTimeInterval(budget)
        let visible = visibleRange?()
        let fix = !(s is NSTextStorage)   // a storage fixes fonts itself (see deferredEdit)
        deferredEdit(s) {
            if let visible, let r = Range(visible) {
                for v in pending.intersection(IndexSet(integersIn: r)).rangeView { styleNow(s, NSRange(location: v.lowerBound, length: v.count), fix: fix) }
            }
            var chunks = 0
            while let first = pending.rangeView.first, chunks < maxChunks, Date() < deadline {
                styleNow(s, NSRange(location: first.lowerBound, length: min(first.count, 1_000)), fix: fix)
                chunks += 1
            }
        }
        schedulePending()
    }

    /// Styles everything still pending (tests; anything that needs the final attributes now).
    func flushPending() {
        guard let s = target, !pending.isEmpty else { return }
        let fix = !(s is NSTextStorage)
        deferredEdit(s) {
            while let first = pending.rangeView.first {
                styleNow(s, NSRange(location: first.lowerBound, length: first.count), fix: fix)
            }
        }
    }

    /// Styles whatever of `r` is still pending, now.
    func styleNow(_ r: NSRange, in s: NSTextStorage) {
        guard let range = Range(r) else { return }
        let todo = pending.intersection(IndexSet(integersIn: range))
        guard !todo.isEmpty else { return }
        deferredEdit(s) {
            for v in todo.rangeView { styleNow(s, NSRange(location: v.lowerBound, length: v.count), fix: false) }
        }
    }

    /// Styles pending text that's on screen (before it's drawn).
    func styleVisiblePending() {
        guard !pending.isEmpty, let visible = visibleRange?(), let s = target as? NSTextStorage else { return }
        styleNow(visible, in: s)
    }

    /// Called before `r` is replaced. NSTextView's undo keeps a copy of the
    /// replaced text with its attributes, and putting back a copy with hundreds
    /// of thousands of attribute runs takes AppKit seconds (it inserts them one
    /// by one). Reduced to its base look, the copy is a few runs; the text is
    /// restyled whenever it comes back. If the edit doesn't happen after all,
    /// `r` is simply restyled later.
    func simplifyBeforeReplacing(_ s: NSMutableAttributedString, _ r: NSRange) {
        guard r.length >= Self.simplifyThreshold, NSMaxRange(r) <= s.length else { return }
        target = s
        collapse(s, r)
        pending.insert(integersIn: r.location..<NSMaxRange(r))
        schedulePending()
    }
    static var simplifyThreshold = 20_000

    /// Runs deferred styling as one storage edit. Afterwards the storage's font
    /// fixing (fallback fonts for emoji, CJK) is done for what was styled, right
    /// away: left to happen lazily, the next keystrokes paid for it.
    private func deferredEdit(_ s: NSMutableAttributedString, _ work: () -> Void) {
        let storage = s as? NSTextStorage
        styledSpan = nil
        storage?.beginEditing()
        work()
        storage?.endEditing()
        if let storage, let span = styledSpan, NSMaxRange(span) <= storage.length { storage.ensureAttributesAreFixed(in: span) }
        styledSpan = nil
    }

    private func schedulePending() {
        guard !pending.isEmpty, !pumpScheduled else { return }
        pumpScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pumpScheduled = false
            self.stylePending(budget: Self.chunkBudget)
        }
    }

    /// Styles the paragraphs covering `r`. `fix` re-runs AppKit's font fallback
    /// (emoji, CJK) there; inside a beginEditing/endEditing pair the storage
    /// does that itself, once, for everything edited. Only the font part:
    /// paragraph styles and attachments are already consistent, and the full
    /// fixAttributes(in:) also checks glyph-info attributes in a way that walks
    /// every attribute run of the page (milliseconds per keystroke on big pages).
    private func styleNow(_ s: NSMutableAttributedString, _ r: NSRange, fix: Bool) {
        let para = s.mutableString.paragraphRange(for: r)
        if para.length > 0 {
            style(s, range: para)
            if fix { s.fixFontAttribute(in: para) }
            styledSpan = styledSpan.map { NSUnionRange($0, para) } ?? para
        }
        pending.remove(integersIn: para.location..<max(para.location, NSMaxRange(para)))
    }

    /// Resets deferred text to its block's base look (body or code) in one
    /// attribute run. Restyling text in place costs time proportional to the
    /// attribute runs after it (they're stored in an array), so restyling a long
    /// stretch of already-styled text near the top of a page was quadratic.
    /// Attachments and their Markdown source are kept.
    private func collapse(_ s: NSMutableAttributedString, _ r: NSRange) {
        guard r.length > 0 else { return }
        let attachments = savedAttachments(s, in: r)
        var loc = r.location
        let end = NSMaxRange(r)
        var bi = 0
        while bi < blocks.count, NSMaxRange(blocks[bi].range) <= loc { bi += 1 }
        while loc < end {
            if bi < blocks.count, blocks[bi].range.location <= loc {
                let stop = min(end, NSMaxRange(blocks[bi].range))
                var attrs = codeAttributes
                attrs[.jotCodeRegion] = blocks[bi].token
                s.setAttributes(attrs, range: NSRange(location: loc, length: stop - loc))
                loc = stop
                bi += 1
            } else {
                let stop = bi < blocks.count ? min(end, blocks[bi].range.location) : end
                s.setAttributes(typingAttributes, range: NSRange(location: loc, length: stop - loc))
                loc = stop
            }
        }
        restore(attachments, in: s)
    }

    // MARK: Fences

    /// The edited paragraphs: [start, oldEnd) before the edit, [start, newEnd) after.
    private struct Edit {
        let start: Int, oldEnd: Int, newEnd: Int
        var delta: Int { newEnd - oldEnd }
        /// Where a position before the edit is now; nil inside the edited paragraphs.
        func map(_ p: Int) -> Int? { p < start ? p : (p >= oldEnd ? p + delta : nil) }
    }

    /// Pairs fence lines into blocks. A block keeps its token (so its lines
    /// needn't be restyled) when its opening fence is the same line as before.
    private func makeBlocks(_ fences: [NSRange], length: Int, reusing old: [Block], edit: Edit?) -> [Block] {
        var byOpen: [Int: CodeRegion] = [:]
        var edited: [CodeRegion] = []   // blocks whose opener was in the edited paragraphs
        if let edit {
            for b in old {
                if let p = edit.map(b.open.location) { byOpen[p] = b.token } else { edited.append(b.token) }
            }
        }
        var new: [Block] = []
        var i = 0
        while i < fences.count {
            let open = fences[i]
            let close = i + 1 < fences.count ? fences[i + 1] : nil
            let end = close.map(NSMaxRange) ?? length   // unclosed: runs to the end
            var token: CodeRegion?
            if let edit, open.location >= edit.start, open.location < edit.newEnd {
                if !edited.isEmpty { token = edited.removeFirst() }
            } else {
                token = byOpen.removeValue(forKey: open.location)
            }
            let t = token ?? CodeRegion()
            t.closed = close != nil
            new.append(Block(range: NSRange(location: open.location, length: end - open.location),
                             open: open, close: close, token: t))
            i += 2
        }
        return new
    }

    /// A stretch of lines that all style the same way inside code: a fence line or a block body.
    private struct Segment { var range: NSRange; var token: ObjectIdentifier; var fence: Bool }

    private func segments(_ blocks: [Block]) -> [Segment] {
        var out: [Segment] = []
        for b in blocks {
            let t = ObjectIdentifier(b.token)
            out.append(Segment(range: b.open, token: t, fence: true))
            let bodyEnd = b.close?.location ?? NSMaxRange(b.range)
            if bodyEnd > NSMaxRange(b.open) {
                out.append(Segment(range: NSRange(location: NSMaxRange(b.open), length: bodyEnd - NSMaxRange(b.open)), token: t, fence: false))
            }
            if let c = b.close { out.append(Segment(range: c, token: t, fence: true)) }
        }
        return out
    }

    /// Characters outside the edit whose role differs between the old and new blocks.
    private func flips(from old: [Block], to new: [Block], edit: Edit) -> IndexSet {
        // Old segments in new coordinates, minus the edited paragraphs.
        var a: [Segment] = []
        for seg in segments(old) {
            let lo = seg.range.location, hi = NSMaxRange(seg.range)
            if lo < edit.start { a.append(Segment(range: NSRange(location: lo, length: min(hi, edit.start) - lo), token: seg.token, fence: seg.fence)) }
            if hi > edit.oldEnd {
                let l = max(lo, edit.oldEnd)
                a.append(Segment(range: NSRange(location: l + edit.delta, length: hi - l), token: seg.token, fence: seg.fence))
            }
        }
        var b: [Segment] = []
        for seg in segments(new) {
            let lo = seg.range.location, hi = NSMaxRange(seg.range)
            if lo < edit.start { b.append(Segment(range: NSRange(location: lo, length: min(hi, edit.start) - lo), token: seg.token, fence: seg.fence)) }
            if hi > edit.newEnd {
                let l = max(lo, edit.newEnd)
                b.append(Segment(range: NSRange(location: l, length: hi - l), token: seg.token, fence: seg.fence))
            }
        }
        var covA = IndexSet(), covB = IndexSet()
        for s in a where s.range.length > 0 { covA.insert(integersIn: s.range.location..<NSMaxRange(s.range)) }
        for s in b where s.range.length > 0 { covB.insert(integersIn: s.range.location..<NSMaxRange(s.range)) }
        var out = covA.symmetricDifference(covB)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let x = a[i], y = b[j]
            let lo = max(x.range.location, y.range.location), hi = min(NSMaxRange(x.range), NSMaxRange(y.range))
            if lo < hi, x.token != y.token || x.fence != y.fence { out.insert(integersIn: lo..<hi) }
            if NSMaxRange(x.range) <= NSMaxRange(y.range) { i += 1 } else { j += 1 }
        }
        return out
    }

    // MARK: Paragraph styling

    private func style(_ s: NSMutableAttributedString, range: NSRange) {
        let ns = s.mutableString
        text = ns.substring(with: range)
        base = range.location
        let str = text
        let end = NSMaxRange(range)
        var loc = range.location
        var bi = 0
        while bi < blocks.count, NSMaxRange(blocks[bi].range) <= loc { bi += 1 }

        repeat {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if para.length == 0 { break }
            var contentLen = para.length
            while contentLen > 0 {
                let c = ns.character(at: para.location + contentLen - 1)
                if c == 10 || c == 13 { contentLen -= 1 } else { break }
            }
            let line = NSRange(location: para.location, length: contentLen)

            while bi < blocks.count, NSMaxRange(blocks[bi].range) <= para.location { bi += 1 }
            let attachments = savedAttachments(s, in: para)
            if bi < blocks.count, blocks[bi].range.location <= para.location {
                styleCodeLine(s, para: para, line: line, block: blocks[bi])
            } else {
                styleLine(s, str: str, para: para, line: line)
            }
            restore(attachments, in: s)
            loc = NSMaxRange(para)
        } while loc < end
    }

    private func styleCodeLine(_ s: NSMutableAttributedString, para: NSRange, line: NSRange, block: Block) {
        let isFence = para.location == block.open.location || para.location == block.close?.location
        s.setAttributes([
            .font: monoFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: codeParagraph,
            .jotCodeRegion: block.token,
        ], range: para)
        if isFence {
            s.addAttribute(.jotFence, value: true, range: para)
            guard line.length > 0 else { return }
            // Hide the backticks; a language tag ("```swift") stays visible, quietly.
            let ns = s.mutableString
            var end = line.location
            while end < NSMaxRange(line), ns.character(at: end) == 32 || ns.character(at: end) == 96 { end += 1 }
            s.addAttribute(.jotHidden, value: true, range: NSRange(location: line.location, length: end - line.location))
            if end < NSMaxRange(line) {
                s.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor,
                                 .font: NSFont.monospacedSystemFont(ofSize: (monoFont.pointSize * 0.85).rounded(), weight: .regular)],
                                range: NSRange(location: end, length: NSMaxRange(line) - end))
            }
        }
    }

    private func styleLine(_ s: NSMutableAttributedString, str: String, para: NSRange, line: NSRange) {
        s.setAttributes(typingAttributes, range: para)
        guard line.length > 0 else { return }

        if first(MarkdownPatterns.rule, line) != nil {
            s.addAttributes([.jotHidden: true, .jotRule: true], range: line)
            return
        }

        var contentStart = line.location
        var font = bodyFont

        if let m = first(MarkdownPatterns.heading, line) {
            let level = m.range(at: 1).length
            font = headingFonts[min(level, headingFonts.count) - 1]
            let p = paragraph("h") {
                let p = self.baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                p.paragraphSpacingBefore = (self.baseSize * 0.5).rounded()
                return p
            }
            s.addAttributes([.font: font, .paragraphStyle: p], range: para)
            s.addAttributes([.jotHidden: true, .jotPrefix: true], range: m.range)
            contentStart = NSMaxRange(m.range)
        } else if let m = first(MarkdownPatterns.quote, line) {
            let p = paragraph("q") {
                let p = self.baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                p.firstLineHeadIndent = 16
                p.headIndent = 16
                return p
            }
            s.addAttributes([.paragraphStyle: p, .jotQuote: true, .foregroundColor: NSColor.secondaryLabelColor], range: para)
            s.addAttributes([.jotHidden: true, .jotPrefix: true], range: m.range)
            contentStart = NSMaxRange(m.range)
        } else if let m = first(MarkdownPatterns.list, line) {
            contentStart = styleListPrefix(s, str: str, match: m, para: para, line: line)
        }

        let content = NSRange(location: contentStart, length: NSMaxRange(line) - contentStart)
        if content.length > 0 { styleInline(s, str: str, range: content, font: font) }
    }

    /// Returns where the item's content starts.
    private func styleListPrefix(_ s: NSMutableAttributedString, str: String, match m: NSTextCheckingResult, para: NSRange, line: NSRange) -> Int {
        let ns = s.mutableString
        let indent = m.range(at: 1)
        let marker = m.range(at: 2)
        let gap = m.range(at: 3)
        let box = m.range(at: 4)
        let level = ListPrefix.level(of: ns.substring(with: indent))

        var prefixEnd = NSMaxRange(m.range)
        var visiblePrefix: String
        if indent.length > 0 { s.addAttribute(.jotHidden, value: true, range: indent) }

        if box.location != NSNotFound {
            // "- [ ] task": hide "- ", draw a checkbox over "[ ]".
            if NSMaxRange(box) < NSMaxRange(line), ns.character(at: NSMaxRange(box)) == 32 { prefixEnd += 1 }
            let checked = !ns.substring(with: box).hasPrefix("[ ]")
            s.addAttribute(.jotHidden, value: true, range: NSUnionRange(marker, gap))
            s.addAttributes([.jotMarker: ListMarker(.checkbox(checked: checked)), .foregroundColor: NSColor.clear], range: box)
            visiblePrefix = "[ ] "
            if checked, prefixEnd < NSMaxRange(line) {
                let rest = NSRange(location: prefixEnd, length: NSMaxRange(line) - prefixEnd)
                s.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor,
                                 .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
            }
        } else if ns.character(at: marker.location) <= 57, ns.character(at: marker.location) >= 48 {
            // Numbered: keep the number visible, just align it.
            s.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: marker)
            visiblePrefix = ns.substring(with: marker) + " "
            if gap.length > 1 { s.addAttribute(.jotHidden, value: true, range: NSRange(location: gap.location + 1, length: gap.length - 1)) }
        } else {
            // "- item": the "-" stays in the text but is drawn as a bullet.
            s.addAttributes([.jotMarker: ListMarker(.bullet(level: level)), .foregroundColor: NSColor.clear], range: marker)
            visiblePrefix = "- "
            if gap.length > 1 { s.addAttribute(.jotHidden, value: true, range: NSRange(location: gap.location + 1, length: gap.length - 1)) }
        }

        s.addAttribute(.jotPrefix, value: true, range: NSRange(location: line.location, length: prefixEnd - line.location))

        // Give every marker the same column width (like Notes) by kerning the
        // space after it, so "•", "1." and "☐" all start their text at one edge.
        let natural = width(of: visiblePrefix)
        let column = max(indentStep, natural)
        let spaceIndex = box.location != NSNotFound ? prefixEnd - 1 : gap.location
        if column > natural, spaceIndex < NSMaxRange(line), ns.character(at: spaceIndex) == 32 {
            s.addAttribute(.kern, value: column - natural, range: NSRange(location: spaceIndex, length: 1))
        }
        let p = paragraph("l\(level)-\(column)") {
            let p = self.baseParagraph.mutableCopy() as! NSMutableParagraphStyle
            p.firstLineHeadIndent = CGFloat(level) * self.indentStep
            p.headIndent = CGFloat(level) * self.indentStep + column
            return p
        }
        s.addAttribute(.paragraphStyle, value: p, range: para)
        return prefixEnd
    }

    // MARK: Inline

    private func styleInline(_ s: NSMutableAttributedString, str: String, range: NSRange, font: NSFont) {
        let ns = s.mutableString
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        func hide(_ r: NSRange) { s.addAttribute(.jotHidden, value: true, range: r) }

        let mono = NSFont.monospacedSystemFont(ofSize: (font.pointSize * 0.9).rounded(), weight: .regular)
        for m in all(MarkdownPatterns.inlineCode, range) {
            hide(NSRange(location: m.range.location, length: 1))
            hide(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            s.addAttributes([.font: mono, .jotInlineCode: true], range: m.range(at: 1))
            taken.append(m.range)
        }

        for m in all(MarkdownPatterns.link, range) where free(m.range) {
            let text = m.range(at: 1)
            let target = ns.substring(with: m.range(at: 2))
            guard let url = Self.url(for: target) else { continue }
            hide(NSRange(location: m.range.location, length: 1))
            hide(NSRange(location: NSMaxRange(text), length: NSMaxRange(m.range) - NSMaxRange(text)))
            s.addAttribute(.link, value: url, range: text)
            taken.append(NSRange(location: NSMaxRange(text), length: NSMaxRange(m.range) - NSMaxRange(text)))
        }

        // Bare URLs before emphasis, so "__dict__" or "/_b_/" inside a URL stay as typed.
        if let detector = MarkdownPatterns.linkDetector {
            for result in all(detector, range) {
                guard let url = result.url, free(result.range),
                      url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" else { continue }
                s.addAttribute(.link, value: url, range: result.range)
                taken.append(result.range)
            }
        }

        // Emphasis may wrap a link or code span ("**[a](b)**"); only its own markers must be free.
        func markersFree(_ m: NSTextCheckingResult, _ mk: Int) -> Bool {
            free(NSRange(location: m.range.location, length: mk)) && free(NSRange(location: NSMaxRange(m.range) - mk, length: mk))
        }
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let u = UnicodeScalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(u) || u == "_"
        }
        for m in all(MarkdownPatterns.bold, range) where markersFree(m, m.range(at: 1).length) {
            // "foo__bar__baz" is literal (CommonMark: no intraword "__").
            if ns.character(at: m.range.location) == 95, isWord(m.range.location - 1) || isWord(NSMaxRange(m.range)) { continue }
            let mk = m.range(at: 1).length
            hide(NSRange(location: m.range.location, length: mk))
            hide(NSRange(location: NSMaxRange(m.range) - mk, length: mk))
            applyTrait(.boldFontMask, s, m.range(at: 2))
        }
        for m in all(MarkdownPatterns.italic, range) where markersFree(m, 1) {
            hide(NSRange(location: m.range.location, length: 1))
            hide(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            applyTrait(.italicFontMask, s, m.range(at: 2))
        }
        for m in all(MarkdownPatterns.strike, range) where markersFree(m, 2) {
            hide(NSRange(location: m.range.location, length: 2))
            hide(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
        }

    }

    private func applyTrait(_ trait: NSFontTraitMask, _ s: NSMutableAttributedString, _ r: NSRange) {
        s.enumerateAttribute(.font, in: r) { value, sub, _ in
            guard let f = value as? NSFont else { return }
            s.addAttribute(.font, value: self.font(f, with: trait), range: sub)
        }
    }

    /// NSFontManager's conversion is slow and styling asks for the same few fonts over and over.
    private var traitCache: [UInt: [NSFont: NSFont]] = [:]
    private func font(_ f: NSFont, with trait: NSFontTraitMask) -> NSFont {
        if let hit = traitCache[trait.rawValue]?[f] { return hit }
        let converted = NSFontManager.shared.convert(f, toHaveTrait: trait)
        traitCache[trait.rawValue, default: [:]][f] = converted
        return converted
    }

    // MARK: Attachments survive restyling

    /// Found through their U+FFFC characters: reading attributes across a big
    /// range would first make the storage fix (font fallback) all of it.
    private func savedAttachments(_ s: NSMutableAttributedString, in r: NSRange) -> [(Int, NSTextAttachment, Any?)] {
        var out: [(Int, NSTextAttachment, Any?)] = []
        guard mayHaveAttachments else { return out }
        let ns = s.mutableString
        var loc = r.location
        while loc < NSMaxRange(r) {
            let hit = ns.range(of: "\u{FFFC}", options: .literal, range: NSRange(location: loc, length: NSMaxRange(r) - loc))
            guard hit.location != NSNotFound else { break }
            if let a = s.attribute(.attachment, at: hit.location, effectiveRange: nil) as? NSTextAttachment {
                out.append((hit.location, a, s.attribute(.jotSource, at: hit.location, effectiveRange: nil)))
            }
            loc = NSMaxRange(hit)
        }
        return out
    }

    private func restore(_ items: [(Int, NSTextAttachment, Any?)], in s: NSMutableAttributedString) {
        for (loc, att, src) in items {
            let r = NSRange(location: loc, length: 1)
            s.addAttribute(.attachment, value: att, range: r)
            if let src { s.addAttribute(.jotSource, value: src, range: r) }
        }
    }

    // MARK: Helpers

    private func local(_ r: NSRange) -> NSRange { NSRange(location: r.location - base, length: r.length) }

    private func first(_ re: NSRegularExpression, _ r: NSRange) -> NSTextCheckingResult? {
        re.firstMatch(in: text, range: local(r))?.adjustingRanges(offset: base)
    }

    private func all(_ re: NSRegularExpression, _ r: NSRange) -> [NSTextCheckingResult] {
        re.matches(in: text, range: local(r)).map { $0.adjustingRanges(offset: base) }
    }

    static func url(for target: String) -> URL? {
        if target.contains("://") || target.hasPrefix("mailto:") { return URL(string: target) }
        return Store.shared.resolve(target)
    }

    private func paragraph(_ key: String, make: () -> NSParagraphStyle) -> NSParagraphStyle {
        if let p = paragraphCache[key] { return p }
        let p = make().copy() as! NSParagraphStyle
        paragraphCache[key] = p
        return p
    }

    private func width(of s: String) -> CGFloat {
        if let w = widthCache[s] { return w }
        let w = ceil((s as NSString).size(withAttributes: [.font: bodyFont]).width)
        widthCache[s] = w
        return w
    }
}
