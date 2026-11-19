import AppKit

/// TextKit 1 layout manager that:
///  - lays out `.jotHidden` characters as null glyphs (zero width, never drawn)
///  - collapses ``` fence lines to a thin padding row
///  - draws bullets / checkboxes over transparent list markers
///  - draws code-block, inline-code, quote and rule decorations
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    weak var styler: MarkdownStyler?
    static let fenceLineHeight: CGFloat = 8

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Hiding

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        let ns = storage.mutableString
        let count = glyphRange.length
        var modified: [NSLayoutManager.GlyphProperty]?
        var runEnd = -1
        var runHidden = false

        for i in 0..<count {
            let ci = charIndexes[i]
            if ci >= runEnd {
                var r = NSRange()
                runHidden = storage.attribute(.jotHidden, at: ci, effectiveRange: &r) != nil
                runEnd = NSMaxRange(r)
            }
            guard runHidden else { continue }
            let c = ns.character(at: ci)
            if c == 10 || c == 13 { continue } // never null a newline (breaks line layout)
            if modified == nil { modified = Array(UnsafeBufferPointer(start: props, count: count)) }
            // Not `.null`: null glyphs at a line start make TextKit lay the rest of
            // the line out with the wrapped-line indent. A control glyph with zero
            // advancement (see shouldUse below) stays put and draws nothing.
            modified![i] = .controlCharacter
        }

        guard let modified else { return 0 }
        modified.withUnsafeBufferPointer { buf in
            setGlyphs(glyphs, properties: buf.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return count
    }

    /// Hidden tabs are still control characters; make them take no space.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if let storage = textStorage, charIndex < storage.length,
           storage.attribute(.jotHidden, at: charIndex, effectiveRange: nil) != nil {
            let c = storage.mutableString.character(at: charIndex)
            if c != 10 && c != 13 { return .zeroAdvancement }
        }
        return action
    }

    /// Line fragment rects for a character range, measured from glyphs that are
    /// actually laid out. Null glyphs report the *previous* line's fragment, so a
    /// fully hidden line ("```", "---") is located through its newline instead.
    private func fragmentBounds(forCharacterRange range: NSRange) -> (top: CGFloat, bottom: CGFloat)? {
        guard let storage = textStorage, range.length > 0 else { return nil }
        let ns = storage.mutableString
        var first = range.location
        while first < NSMaxRange(range) - 1, storage.attribute(.jotHidden, at: first, effectiveRange: nil) != nil,
              ns.character(at: first) != 10 { first += 1 }
        let last = NSMaxRange(range) - 1
        let topRect = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: first), effectiveRange: nil)
        let bottomRect = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: last), effectiveRange: nil)
        return (topRect.minY, max(bottomRect.maxY, topRect.maxY))
    }

    // MARK: Fence lines

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage, glyphRange.length > 0 else { return false }
        let ci = characterIndexForGlyph(at: glyphRange.location)
        guard ci < storage.length, storage.attribute(.jotFence, at: ci, effectiveRange: nil) != nil else { return false }
        let h = Self.fenceLineHeight
        lineFragmentRect.pointee.size.height = h
        lineFragmentUsedRect.pointee.size.height = h
        baselineOffset.pointee = h - 2
        return true
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let full = NSRange(location: 0, length: storage.length)
        let pad = container.lineFragmentPadding

        // Code blocks: one rounded rect per block, even if only part is visible.
        var seen = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.jotCodeRegion, in: chars) { value, run, _ in
            guard let token = value as? CodeRegion, seen.insert(ObjectIdentifier(token)).inserted else { return }
            var region = NSRange()
            _ = storage.attribute(.jotCodeRegion, at: run.location, longestEffectiveRange: &region, in: full)
            guard let (top, bottom) = self.fragmentBounds(forCharacterRange: region), bottom > top else { return }
            let box = NSRect(x: origin.x + pad, y: origin.y + top, width: container.size.width - pad * 2, height: bottom - top)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        }

        // Inline code pills.
        storage.enumerateAttribute(.jotInlineCode, in: chars) { value, range, _ in
            guard value != nil else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let r = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 0)
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            }
        }

        // Quote bars and horizontal rules.
        storage.enumerateAttribute(.jotQuote, in: chars) { value, range, _ in
            guard value != nil, let (top, bottom) = self.fragmentBounds(forCharacterRange: range) else { return }
            let bar = NSRect(x: origin.x + pad + 2, y: origin.y + top + 2, width: 3, height: bottom - top - 4)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
        storage.enumerateAttribute(.jotRule, in: chars) { value, range, _ in
            guard value != nil else { return }
            // The rule's own characters are null glyphs; locate the line via its end.
            let para = storage.mutableString.paragraphRange(for: range)
            guard let (top, bottom) = self.fragmentBounds(forCharacterRange: NSRange(location: NSMaxRange(para) - 1, length: 1)) else { return }
            let y = (origin.y + (top + bottom) / 2).rounded() + 0.5
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: origin.x + pad, y: y))
            path.line(to: NSPoint(x: origin.x + container.size.width - pad, y: y))
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.jotMarker, in: chars) { value, range, _ in
            guard let marker = value as? ListMarker else { return }
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 15)
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = self.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let line = self.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let baseline = origin.y + line.minY + self.location(forGlyphAt: glyphs.location).y
            let midY = baseline - font.xHeight / 2
            // Bullets and checkboxes share one centre line so mixed lists align.
            let centerX = box.minX + (self.styler?.indentStep ?? 24) * 0.36

            switch marker.kind {
            case .bullet(let level):
                let symbols = ["•", "◦", "▪︎"]
                let s = symbols[level % symbols.count] as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
                let size = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: centerX - size.width / 2, y: baseline - font.ascender), withAttributes: attrs)
            case .checkbox(let checked):
                let name = checked ? "checkmark.circle.fill" : "circle"
                let color = checked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
                let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 1.05, weight: .regular)
                    .applying(.init(paletteColors: [color]))
                guard let img = NSImage(systemSymbolName: name, accessibilityDescription: checked ? "Done" : "To do")?
                    .withSymbolConfiguration(config) else { return }
                let size = img.size
                let rect = NSRect(x: centerX - size.width / 2, y: midY - size.height / 2, width: size.width, height: size.height)
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    // MARK: Hit testing

    /// Character range of the checkbox under `point` (text-container coordinates), if any.
    func checkbox(at point: NSPoint) -> NSRange? {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return nil }
        let g = glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        let line = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let lineChars = characterRange(forGlyphRange: glyphRange(forBoundingRect: line, in: container), actualGlyphRange: nil)
        var hit: NSRange?
        storage.enumerateAttribute(.jotMarker, in: lineChars) { value, range, stop in
            guard let m = value as? ListMarker, case .checkbox = m.kind else { return }
            let rect = self.boundingRect(forGlyphRange: self.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            if rect.insetBy(dx: -4, dy: -3).contains(point) { hit = range; stop.pointee = true }
        }
        return hit
    }
}
