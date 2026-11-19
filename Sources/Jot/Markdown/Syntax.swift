import AppKit

/// Custom attributes the styler writes onto the Markdown text storage.
/// The layout manager reads them to hide or decorate characters. The stored
/// string itself is never rewritten while you type.
extension NSAttributedString.Key {
    /// Laid out as a zero-width null glyph (never drawn). Never set on newlines.
    static let jotHidden = NSAttributedString.Key("jot.hidden")
    /// Block prefix ("\t- ", "## ", "> "): the caret is never allowed inside it.
    static let jotPrefix = NSAttributedString.Key("jot.prefix")
    /// List marker characters, drawn transparent; the layout manager paints a
    /// bullet / checkbox over them.
    static let jotMarker = NSAttributedString.Key("jot.marker")
    /// Thematic break line ("---").
    static let jotRule = NSAttributedString.Key("jot.rule")
    /// Fenced code block; value is a CodeRegion shared by all lines of a block.
    static let jotCodeRegion = NSAttributedString.Key("jot.codeRegion")
    /// The ``` line itself (collapsed to a thin padding row).
    static let jotFence = NSAttributedString.Key("jot.fence")
    static let jotInlineCode = NSAttributedString.Key("jot.inlineCode")
    static let jotQuote = NSAttributedString.Key("jot.quote")
    /// On an attachment character: the Markdown it stands for, e.g. "![](attachments/x.png)".
    static let jotSource = NSAttributedString.Key("jot.source")
}

/// Identity-compared token so adjacent code blocks don't merge into one run.
final class CodeRegion: NSObject {
    var closed = true
}

final class ListMarker: NSObject {
    enum Kind {
        case bullet(level: Int)
        case checkbox(checked: Bool)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

enum MarkdownPatterns {
    private static func re(_ p: String) -> NSRegularExpression {
        // Patterns are constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: p, options: [])
    }

    static let rule = re(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    static let heading = re(#"^(#{1,6})[ \t]+"#)
    static let quote = re(#"^>[ \t]?"#)
    /// 1: indent, 2: marker, 3: whitespace after marker, 4: optional "[ ]" box
    static let list = re(#"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\](?=[ \t]|$))?"#)

    static let inlineCode = re(#"`([^`\n]+)`"#)
    /// The URL may contain balanced parentheses (Wikipedia's "C_(programming_language)").
    static let link = re(#"(?<!!)\[([^\]\n]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)"#)
    static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    /// The marker must not be the "*" of a keycap emoji (*️⃣).
    static let italic = re(#"(?<![\*\w])([\*_])(?![\x{FE0F}\x{20E3}])(?=[^\s\*_])(.+?)(?<=[^\s\*_])\1(?![\*\w\x{FE0F}\x{20E3}])"#)
    static let strike = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)

    /// Local images/files that become inline objects: ![alt](path) and [name](attachments/…)
    /// The path may contain balanced parentheses ("a(1).png").
    static let atom = re(#"(!?)\[([^\]\n]*)\]\(((?:attachments/|file://)(?:[^()\s]|\([^()\s]*\))+)\)"#)

    static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

/// Fenced code blocks, CommonMark-ish: an opening fence's info string has no
/// backticks ("```x``` inline" is prose), and a closing fence is only backticks,
/// at least as many as opened it. Returns fence lines in open/close pairs (a
/// trailing unpaired one is an unclosed block). Shared by styling and Atoms.
enum Fences {
    static func scan(_ ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var openTicks = 0
        var loc = 0
        let len = ns.length
        while loc < len {
            let r = ns.range(of: "```", options: .literal, range: NSRange(location: loc, length: len - loc))
            if r.location == NSNotFound { break }
            let line = ns.paragraphRange(for: NSRange(location: r.location, length: 0))
            loc = NSMaxRange(line)
            let lead = r.location - line.location
            guard lead <= 3, lead == 0 || ns.substring(with: NSRange(location: line.location, length: lead)).allSatisfy({ $0 == " " }) else { continue }
            var i = r.location
            while i < NSMaxRange(line), ns.character(at: i) == 96 { i += 1 }
            let ticks = i - r.location
            let rest = ns.substring(with: NSRange(location: i, length: NSMaxRange(line) - i))
            if openTicks == 0 {
                guard !rest.contains("`") else { continue }
                openTicks = ticks
                result.append(line)
            } else if ticks >= openTicks, rest.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" }) {
                openTicks = 0
                result.append(line)
            }
        }
        return result
    }

    /// Normalises every kind of line break to "\n". Paragraph and line
    /// separators (U+2028/2029/0085) and lone "\r" would otherwise give lines that
    /// NSString's line and paragraph ranges disagree about.
    static func normalizeNewlines(_ s: String) -> String {
        guard s.contains(where: { $0 == "\r" || $0 == "\r\n" || $0 == "\u{2028}" || $0 == "\u{2029}" || $0 == "\u{85}" }) else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{85}", with: "\n")
    }
}

/// Parsed list prefix of a single line (shared by styler and editor commands).
struct ListPrefix {
    var indent: String
    var marker: String
    var checkbox: Bool?      // nil = not a checklist item
    var length: Int          // UTF-16 length of the whole prefix (incl. trailing space)

    var level: Int { ListPrefix.level(of: indent) }
    var isNumbered: Bool { marker.first?.isNumber == true }

    static func level(of indent: String) -> Int {
        var tabs = 0, spaces = 0
        for ch in indent { if ch == "\t" { tabs += 1 } else { spaces += 1 } }
        return tabs + Int((Double(spaces) / 4).rounded(.up))
    }

    static func parse(_ line: String) -> ListPrefix? {
        let ns = line as NSString
        guard let m = MarkdownPatterns.list.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let box = m.range(at: 4)
        var length = m.range.length
        if box.location != NSNotFound {
            // include the space after "[ ]" if present
            if NSMaxRange(box) < ns.length, ns.character(at: NSMaxRange(box)) == 32 { length += 1 }
        }
        return ListPrefix(
            indent: ns.substring(with: m.range(at: 1)),
            marker: ns.substring(with: m.range(at: 2)),
            checkbox: box.location == NSNotFound ? nil : !ns.substring(with: box).hasPrefix("[ ]"),
            length: length
        )
    }

    /// The prefix for the next item when pressing Return.
    func continuation() -> String {
        var next = marker
        if isNumbered, let n = Int(marker.dropLast()) { next = "\(n + 1)\(marker.last!)" }
        return indent + next + " " + (checkbox != nil ? "[ ] " : "")
    }
}
