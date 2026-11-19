import AppKit
import UniformTypeIdentifiers

/// Images and files live in the editor as single attachment characters
/// (U+FFFC) that remember their Markdown. They're decoded when text comes in
/// (load, paste) and encoded back when text goes out (save, copy).
enum Atoms {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp"]

    static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Markdown text → attributed string with attachments in place of local images/files.
    static func decode(_ markdown: String, styler: MarkdownStyler) -> NSAttributedString {
        let out = NSMutableAttributedString(string: markdown, attributes: styler.typingAttributes)
        let ns = markdown as NSString
        let matches = MarkdownPatterns.atom.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let bang = m.range(at: 1).length == 1
            let name = ns.substring(with: m.range(at: 2))
            let path = ns.substring(with: m.range(at: 3))
            let source = ns.substring(with: m.range)
            let atom = make(source: source, path: path, name: name, asImage: bang && isImage(path), styler: styler)
            out.replaceCharacters(in: m.range, with: atom)
        }
        return out
    }

    /// Attributed range → Markdown, expanding attachments back to their source.
    static func encode(_ s: NSAttributedString, range: NSRange) -> String {
        var result = ""
        let ns = s.string as NSString
        var cursor = range.location
        s.enumerateAttribute(.jotSource, in: range) { value, r, _ in
            guard let src = value as? String else { return }
            if r.location > cursor { result += ns.substring(with: NSRange(location: cursor, length: r.location - cursor)) }
            // one source per attachment character
            for _ in 0..<r.length { result += src }
            cursor = NSMaxRange(r)
        }
        if cursor < NSMaxRange(range) { result += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor)) }
        return result
    }

    static func make(source: String, path: String, name: String, asImage: Bool, styler: MarkdownStyler) -> NSAttributedString {
        let url = MarkdownStyler.url(for: path) ?? URL(fileURLWithPath: path)
        let attachment = NSTextAttachment()
        if asImage {
            attachment.attachmentCell = ImageAttachmentCell(url: url)
        } else {
            let display = name.isEmpty ? url.lastPathComponent : name
            attachment.attachmentCell = FileChipCell(url: url, name: display, styler: styler)
        }
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttributes(styler.typingAttributes, range: NSRange(location: 0, length: s.length))
        s.addAttribute(.jotSource, value: source, range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Markdown for a file that was just copied into attachments/.
    static func markdown(forImported relativePath: String, originalName: String) -> String {
        if isImage(relativePath) { return "![](\(relativePath))" }
        let safe = originalName.replacingOccurrences(of: "]", with: ")")
        return "[\(safe)](\(relativePath))"
    }
}

// MARK: - Cells

/// Image drawn inline, scaled to fit the text width.
final class ImageAttachmentCell: NSTextAttachmentCell {
    let url: URL
    private lazy var loaded: NSImage? = NSImage(contentsOf: url)
    private static let maxHeight: CGFloat = 420

    init(url: URL) {
        self.url = url
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError() }

    private func fittedSize(maxWidth: CGFloat) -> NSSize {
        guard let img = loaded, img.size.width > 0, img.size.height > 0 else { return NSSize(width: 160, height: 28) }
        var w = min(img.size.width, max(maxWidth, 40))
        var h = w * img.size.height / img.size.width
        if h > Self.maxHeight { h = Self.maxHeight; w = h * img.size.width / img.size.height }
        return NSSize(width: floor(w), height: floor(h))
    }

    override func cellSize() -> NSSize { fittedSize(maxWidth: 480) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let size = fittedSize(maxWidth: lineFrag.width - position.x - textContainer.lineFragmentPadding * 2)
        return NSRect(x: 0, y: 0, width: size.width, height: size.height + 6)
    }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let frame = NSRect(x: cellFrame.minX, y: cellFrame.minY + 3, width: cellFrame.width, height: cellFrame.height - 6)
        guard let img = loaded else {
            let msg = "Missing image" as NSString
            msg.draw(at: NSPoint(x: frame.minX + 4, y: frame.minY + 4),
                     withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor])
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).addClip()
        img.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard flag else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0, dy: 3), xRadius: 8, yRadius: 8).fill()
    }

    override func wantsToTrackMouse() -> Bool { false }
}

/// Small rounded "icon + name" pill for non-image files.
final class FileChipCell: NSTextAttachmentCell {
    let url: URL
    let name: String
    private weak var styler: MarkdownStyler?

    init(url: URL, name: String, styler: MarkdownStyler) {
        self.url = url
        self.name = name
        self.styler = styler
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    private var chipFont: NSFont { NSFont.systemFont(ofSize: max((styler?.baseSize ?? 15) - 1, 10), weight: .medium) }
    private var iconSize: CGFloat { (chipFont.pointSize * 1.2).rounded() }

    override func cellSize() -> NSSize {
        let textW = ceil((name as NSString).size(withAttributes: [.font: chipFont]).width)
        let h = ceil(chipFont.ascender - chipFont.descender) + 6
        return NSSize(width: min(8 + iconSize + 5 + textW + 10, 360), height: h)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: floor(chipFont.descender) - 3) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let pill = cellFrame.insetBy(dx: 1, dy: 0)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let iconRect = NSRect(x: pill.minX + 7, y: pill.midY - iconSize / 2, width: iconSize, height: iconSize)
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        let textX = iconRect.maxX + 5
        let textRect = NSRect(x: textX, y: pill.midY - (chipFont.ascender - chipFont.descender) / 2,
                              width: pill.maxX - textX - 8, height: chipFont.ascender - chipFont.descender)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        (name as NSString).draw(in: textRect, withAttributes: [.font: chipFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard flag else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: cellFrame, xRadius: 7, yRadius: 7).fill()
    }

    override func wantsToTrackMouse() -> Bool { false }
}
