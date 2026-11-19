import AppKit

/// Turns Markdown text into display attributes, one paragraph at a time.
/// Only the edited paragraphs are restyled on each keystroke; code fences are
/// tracked with a cheap whole-document scan so a new ``` restyles what follows.
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
    private var fenceCount = 0

    init() { rebuild() }

    var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraph]
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
    }

    // MARK: Entry points (called from the text storage delegate)

    /// Restyles whatever an edit could have affected. Returns the restyled range.
    func restyle(_ s: NSMutableAttributedString, edited: NSRange, delta: Int) -> NSRange {
        let ns = s.mutableString
        var range = ns.paragraphRange(for: edited)

        // Fences only need a full rescan when the edited lines had or have one;
        // otherwise the known fence lines just shift by the edit's length.
        let oldStart = range.location, oldEnd = NSMaxRange(range) - delta
        let touchedOld = fenceLines.contains { $0.location <= oldEnd && NSMaxRange($0) > oldStart }
        let hasNew = ns.range(of: "```", options: .literal, range: range).location != NSNotFound
        let fences = (touchedOld || hasNew)
            ? scanFences(ns)
            : fenceLines.map { $0.location >= oldEnd ? NSRange(location: $0.location + delta, length: $0.length) : $0 }
        fenceLines = fences

        let countChanged = fences.count != fenceCount
        if countChanged {
            // Pairing shifted: everything from here down may flip in/out of code.
            range = NSRange(location: range.location, length: ns.length - range.location)
        }
        rebuildBlocks(fences, length: ns.length, keepAllTokens: !countChanged, keepBefore: range.location)
        // An edit touching a fence line restyles the whole block it belongs to.
        if fences.contains(where: { NSIntersectionRange($0, range).length > 0 || $0.location == range.location }) {
            for b in blocks where NSIntersectionRange(b.range, range).length > 0 || b.range.location == range.location {
                range = NSUnionRange(range, b.range)
            }
        }
        style(s, range: range)
        return range
    }

    func restyleAll(_ s: NSMutableAttributedString) {
        let ns = s.mutableString
        fenceCount = -1
        fenceLines = scanFences(ns)
        rebuildBlocks(fenceLines, length: ns.length, keepAllTokens: false, keepBefore: 0)
        style(s, range: NSRange(location: 0, length: ns.length))
    }

    // MARK: Fences

    private func scanFences(_ ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var loc = 0
        let len = ns.length
        while loc < len {
            let r = ns.range(of: "```", options: .literal, range: NSRange(location: loc, length: len - loc))
            if r.location == NSNotFound { break }
            let line = ns.lineRange(for: NSRange(location: r.location, length: 0))
            let lead = r.location - line.location
            if lead <= 3, lead == 0 || ns.substring(with: NSRange(location: line.location, length: lead)).allSatisfy({ $0 == " " }) {
                result.append(line)
            }
            loc = NSMaxRange(line)
        }
        return result
    }

    private func rebuildBlocks(_ fences: [NSRange], length: Int, keepAllTokens: Bool, keepBefore: Int) {
        let old = blocks
        var new: [Block] = []
        var i = 0
        while i < fences.count {
            let open = fences[i]
            let close = i + 1 < fences.count ? fences[i + 1] : nil
            let end = close.map(NSMaxRange) ?? length   // unclosed: runs to the end
            let idx = new.count
            let reuse = idx < old.count && (keepAllTokens || open.location < keepBefore)
            let token = reuse ? old[idx].token : CodeRegion()
            token.closed = close != nil
            new.append(Block(range: NSRange(location: open.location, length: end - open.location),
                             open: open, close: close, token: token))
            i += 2
        }
        blocks = new
        fenceCount = fences.count
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
            if line.length > 0 { s.addAttribute(.jotHidden, value: true, range: line) }
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

        for m in all(MarkdownPatterns.bold, range) where free(m.range) {
            let mk = m.range(at: 1).length
            hide(NSRange(location: m.range.location, length: mk))
            hide(NSRange(location: NSMaxRange(m.range) - mk, length: mk))
            applyTrait(.boldFontMask, s, m.range(at: 2))
        }
        for m in all(MarkdownPatterns.italic, range) where free(m.range) {
            hide(NSRange(location: m.range.location, length: 1))
            hide(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            applyTrait(.italicFontMask, s, m.range(at: 2))
        }
        for m in all(MarkdownPatterns.strike, range) where free(m.range) {
            hide(NSRange(location: m.range.location, length: 2))
            hide(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
        }

        if let detector = MarkdownPatterns.linkDetector {
            for result in all(detector, range) {
                guard let url = result.url, free(result.range),
                      url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" else { continue }
                s.addAttribute(.link, value: url, range: result.range)
            }
        }
    }

    private func applyTrait(_ trait: NSFontTraitMask, _ s: NSMutableAttributedString, _ r: NSRange) {
        s.enumerateAttribute(.font, in: r) { value, sub, _ in
            guard let f = value as? NSFont else { return }
            s.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: trait), range: sub)
        }
    }

    // MARK: Attachments survive restyling

    private func savedAttachments(_ s: NSMutableAttributedString, in r: NSRange) -> [(Int, NSTextAttachment, Any?)] {
        var out: [(Int, NSTextAttachment, Any?)] = []
        s.enumerateAttribute(.attachment, in: r) { value, sub, _ in
            guard let a = value as? NSTextAttachment else { return }
            out.append((sub.location, a, s.attribute(.jotSource, at: sub.location, effectiveRange: nil)))
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
