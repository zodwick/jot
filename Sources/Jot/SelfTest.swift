import AppKit

/// `JOT_SELFTEST=1 Jot` runs scripted editing cases through the real editor
/// (same command methods a key press triggers) and exits non-zero on failure.
/// "|" in a case marks the caret (or "[" … "]" style selection via `select`).
private extension NSAttributedString {
    func attribute(_ key: Key, in range: NSRange) -> Any? {
        var found: Any?
        enumerateAttribute(key, in: range) { v, _, stop in if v != nil { found = v; stop.pointee = true } }
        return found
    }
}

enum SelfTest {
    static func run() -> Never {
        var failures = 0
        var passed = 0

        func check(_ name: String, _ start: String, select: NSRange? = nil,
                   expect: String, _ action: (EditorTextView) -> Void) {
            let stack = MarkdownEditorStack()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            window.contentView = stack.textView
            let caret = (start as NSString).range(of: "|").location
            stack.load(markdown: start.replacingOccurrences(of: "|", with: ""))
            let tv = stack.textView
            if let select { tv.setSelectedRange(select) }
            else if caret != NSNotFound { tv.setSelectedRange(NSRange(location: caret, length: 0)) }
            action(tv)
            var out = stack.markdown()
            let sel = tv.selectedRange()
            if sel.length == 0 {
                // Re-encode the caret position into markdown coordinates (no atoms in these cases).
                out.insert("|", at: out.index(out.startIndex, offsetBy: min(sel.location, out.count)))
            }
            if out == expect {
                passed += 1
            } else {
                failures += 1
                print("FAIL \(name)\n  expected: \(expect.debugDescription)\n  got:      \(out.debugDescription)")
            }
        }

        check("checklist continues", "- [ ] buy milk|", expect: "- [ ] buy milk\n- [ ] |") { $0.insertNewline(nil) }
        check("bullet continues", "- item|", expect: "- item\n- x|") { tv in
            tv.insertNewline(nil); tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        check("empty item ends list", "- a\n- |", expect: "- a\n|") { $0.insertNewline(nil) }
        check("number increments", "1. one|", expect: "1. one\n2. |") { $0.insertNewline(nil) }
        check("tab nests item", "- a\n- b|", expect: "- a\n\t- b|") { $0.insertTab(nil) }
        check("shift-tab outdents", "- a\n\t- b|", expect: "- a\n- b|") { $0.insertBacktab(nil) }
        check("empty nested item outdents", "- a\n\t- |", expect: "- a\n- |") { $0.insertNewline(nil) }
        check("backspace removes bullet", "- |foo", expect: "|foo") { $0.deleteBackward(nil) }
        check("backspace outdents nested", "- a\n\t- |foo", expect: "- a\n- |foo") { $0.deleteBackward(nil) }
        check("backspace removes heading", "# |Title", expect: "|Title") { $0.deleteBackward(nil) }
        check("backspace skips hidden **", "a **bold**|", expect: "a **bol|**") { $0.deleteBackward(nil) }
        check("[] becomes checkbox", "[]|", expect: "- [ ] |") { $0.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        check("fence auto-closes", "```|", expect: "```\n|\n```") { $0.insertNewline(nil) }
        check("code keeps indent", "```\n    foo|\n```", expect: "```\n    foo\n    |\n```") { $0.insertNewline(nil) }
        check("left leaves item to prev line", "- a\n- |b", expect: "- a|\n- b") { $0.moveLeft(nil) }
        check("right enters item content", "- a|\n- b", expect: "- a\n- |b") { $0.moveRight(nil) }
        check("right skips hidden **", "x|**b**", expect: "x**b|**") { $0.moveRight(nil) }
        check("caret never inside prefix", "|- foo", expect: "- |foo") { _ in }
        check("bold wraps selection", "a word b", select: NSRange(location: 2, length: 4), expect: "a **word** b") { $0.toggleBold(nil) }
        check("bold unwraps", "a **word** b", select: NSRange(location: 4, length: 4), expect: "a word b") { $0.toggleBold(nil) }
        check("bullet toggle", "one\ntwo", select: NSRange(location: 0, length: 7), expect: "- one\n- two") { $0.toggleBulletList(nil) }
        // Typing anywhere but a line's end must keep the caret where you type
        // (restyling the line once moved it to the line's end).
        func type(_ tv: EditorTextView, _ s: String) {
            for ch in s { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        check("type on empty middle line", "one\n|\nthree", expect: "one\nabc|\nthree") { type($0, "abc") }
        check("type at start of middle line", "one\n|mid\nthree", expect: "one\nabc|mid\nthree") { type($0, "abc") }
        check("type inside a line", "one\nm|id\nthree", expect: "one\nmabc|id\nthree") { type($0, "abc") }
        check("type then delete on empty line", "one\n|\nthree", expect: "one\n|\nthree") { tv in
            type(tv, "abc"); tv.deleteBackward(nil); tv.deleteBackward(nil); tv.deleteBackward(nil)
        }
        check("type inside a list item", "- one|x\n- two", expect: "- oneabc|x\n- two") { type($0, "abc") }
        check("type inside bold", "a **bo|ld** b", expect: "a **boabc|ld** b") { type($0, "abc") }
        check("type in code block", "```\nf|oo\n```", expect: "```\nfabc|oo\n```") { type($0, "abc") }
        // Collapsed "---" / ``` lines.
        check("backspace un-hides rule", "---|", expect: "--|") { $0.deleteBackward(nil) }
        check("backspace after rule removes it", "a\n---\n|b", expect: "a\n|b") { $0.deleteBackward(nil) }
        check("backspace after fence steps over it", "```\ncode\n```\n|b", expect: "```\ncode|\n```\nb") { $0.deleteBackward(nil) }
        check("right skips closing fence", "```\ncode|\n```\nafter", expect: "```\ncode\n```\n|after") { $0.moveRight(nil) }
        check("left skips closing fence", "```\ncode\n```\n|after", expect: "```\ncode|\n```\nafter") { $0.moveLeft(nil) }
        check("caret never inside a fence", "```\ncode\n`|``\nafter", expect: "```\ncode\n```|\nafter") { _ in }
        // Return.
        check("return at heading start pushes it down", "# |Title", expect: "\n# |Title") { $0.insertNewline(nil) }
        check("return renumbers the list below", "1. a|\n2. b\n3. c", expect: "1. a\n2. |\n3. b\n4. c") { $0.insertNewline(nil) }
        check("return over selection in item", "- abcd", select: NSRange(location: 3, length: 2), expect: "- a\n- |d") { $0.insertNewline(nil) }
        // Selections and word/line deletes never eat prefixes or leave half a marker pair.
        check("selection into bullet is snapped", "x\n- item", select: NSRange(location: 2, length: 6), expect: "x\n- |") { $0.deleteBackward(nil) }
        check("cmd-delete keeps bullet", "- item|", expect: "- |") { $0.deleteToBeginningOfLine(nil) }
        check("option-delete over bold", "a **bold**|", expect: "a |") { $0.deleteWordBackward(nil) }
        check("option-delete past bold", "x **bold** |", expect: "x |") { $0.deleteWordBackward(nil) }
        check("backspace empties a span", "a **b**|", expect: "a |") { $0.deleteBackward(nil) }
        check("forward delete empties a span", "a |`c`", expect: "a |") { $0.deleteForward(nil) }
        check("backspace into heading prefix", "x\n# **b**|", expect: "x\n|**b**") { tv in tv.moveLeft(nil); tv.deleteBackward(nil) }
        check("shift-left selects the visible letter", "x **bold**|", expect: "x **bol|**") { tv in
            tv.moveLeftAndModifySelection(nil); tv.deleteBackward(nil)
        }
        check("deleting a selection keeps markers", "a **bold** b", select: NSRange(location: 4, length: 6), expect: "a | b") { $0.deleteBackward(nil) }
        // Formatting commands.
        check("bold toggle unwraps around caret", "a **bo|ld** b", expect: "a bo|ld b") { $0.toggleBold(nil) }
        check("bold trims trailing space", "a word b", select: NSRange(location: 2, length: 5), expect: "a **word** b") { $0.toggleBold(nil) }
        check("[] on an empty bullet", "- |", expect: "- [ ] |") { tv in
            tv.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0))
            tv.insertText("]", replacementRange: NSRange(location: NSNotFound, length: 0))
            tv.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        check("tab indents lines in code", "```\na\nb\n```", select: NSRange(location: 4, length: 3), expect: "```\n\ta\n\tb\n```") { $0.insertTab(nil) }
        check("ctrl-return is a newline", "a|b", expect: "a\n|b") { $0.insertLineBreak(nil) }

        check("checkbox toggle via text", "- [ ] a|", expect: "- [ ] a\n- [ ] b|") { tv in
            tv.insertNewline(nil); tv.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        // Atoms round-trip through load → save and copy.
        do {
            let stack = MarkdownEditorStack()
            let md = "before ![](attachments/a.png) mid [r.pdf](attachments/r.pdf) after\n"
            stack.load(markdown: md)
            let len = stack.storage.length
            if stack.markdown() == md, len < (md as NSString).length { passed += 1 }
            else { failures += 1; print("FAIL atoms round-trip: \(stack.markdown().debugDescription) len=\(len)") }

            let pb = NSPasteboard(name: NSPasteboard.Name("jot.selftest"))
            stack.textView.setSelectedRange(NSRange(location: 0, length: len))
            _ = stack.textView.writeSelection(to: pb, types: [.string])
            if pb.string(forType: .string) == md { passed += 1 }
            else { failures += 1; print("FAIL copy as markdown: \(String(describing: pb.string(forType: .string)))") }
            pb.releaseGlobally()
        }

        // Pasting a file copies it into attachments/ and inserts a chip; pasting
        // image data saves a PNG and inserts it on its own line.
        do {
            let stack = MarkdownEditorStack()
            stack.load(markdown: "notes ")
            stack.textView.setSelectedRange(NSRange(location: 6, length: 0))
            let src = FileManager.default.temporaryDirectory.appendingPathComponent("jot-selftest report.pdf")
            try? Data("pdf".utf8).write(to: src)
            let pb = NSPasteboard(name: NSPasteboard.Name("jot.selftest.files"))
            pb.clearContents()
            pb.writeObjects([src as NSURL])
            _ = stack.textView.readSelection(from: pb, type: .fileURL)
            let md = stack.markdown()
            let rel = md.components(separatedBy: "](").last.map { String($0.dropLast()) } ?? ""
            if md.hasPrefix("notes [jot-selftest report.pdf](attachments/"),
               FileManager.default.fileExists(atPath: Store.shared.resolve(rel).path) { passed += 1 }
            else { failures += 1; print("FAIL paste file: \(md.debugDescription)") }

            let img = NSImage(size: NSSize(width: 20, height: 10))
            img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 20, height: 10).fill(); img.unlockFocus()
            pb.clearContents()
            pb.setData(img.tiffRepresentation, forType: .tiff)
            stack.textView.setSelectedRange(NSRange(location: stack.storage.length, length: 0))
            _ = stack.textView.readSelection(from: pb, type: .tiff)
            let md2 = stack.markdown()
            if md2.contains("\n![](attachments/image-"), md2.hasSuffix(".png)") { passed += 1 }
            else { failures += 1; print("FAIL paste image: \(md2.debugDescription)") }
            pb.releaseGlobally()
        }

        // Emoji typed into styled text keep their fallback font (no tofu boxes).
        do {
            let stack = MarkdownEditorStack()
            stack.load(markdown: "**hi **")
            stack.textView.setSelectedRange(NSRange(location: 5, length: 0))
            stack.textView.insertText("😀", replacementRange: NSRange(location: NSNotFound, length: 0))
            let font = stack.storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
            if font?.fontName.contains("Emoji") == true { passed += 1 }
            else { failures += 1; print("FAIL emoji font: \(String(describing: font?.fontName))") }
        }

        // Styling: what the user sees after edits matches a fresh load of the same text.
        do {
            func styled(_ md: String, at: Int, _ action: (EditorTextView) -> Void, _ test: (MarkdownEditorStack) -> Bool, _ name: String) {
                let stack = MarkdownEditorStack()
                stack.load(markdown: md)
                stack.textView.setSelectedRange(NSRange(location: at, length: 0))
                action(stack.textView)
                if test(stack) { passed += 1 } else { failures += 1; print("FAIL \(name): \(stack.markdown().debugDescription)") }
            }
            func font(_ st: MarkdownEditorStack, _ i: Int) -> CGFloat { (st.storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
            func hidden(_ st: MarkdownEditorStack, _ i: Int) -> Bool { st.storage.attribute(.jotHidden, at: i, effectiveRange: nil) != nil }
            styled("# Hello world", at: 8, { $0.insertNewline(nil) }, { font($0, 9) == 15 }, "return mid-heading restyles the new line")
            styled("> quoted text", at: 8, { $0.insertNewline(nil) }, { $0.storage.attribute(.jotQuote, at: 10, effectiveRange: nil) == nil }, "return mid-quote restyles the new line")
            styled("see ```js\nx", at: 4, { $0.insertNewline(nil) }, { $0.storage.attribute(.jotCodeRegion, at: 11, effectiveRange: nil) != nil }, "return before ``` opens a block")
            styled("```swift\ncode\n```", at: 0, { _ in }, { !hidden($0, 3) && hidden($0, 2) }, "fence language tag visible")
            styled("```x``` is inline\nafter", at: 0, { _ in }, { $0.storage.attribute(.jotCodeRegion, at: 20, effectiveRange: nil) == nil }, "inline triple backticks are prose")
            styled("**[a](https://x.com)**", at: 0, { _ in }, { hidden($0, 0) && hidden($0, 21) }, "bold around a link")
            styled("https://x.org/a#o.__dict__ ok", at: 0, { _ in }, { !hidden($0, 17) }, "no emphasis inside URLs")
            styled("foo__bar__baz", at: 0, { _ in }, { !hidden($0, 3) }, "intraword __ is literal")
            styled("[C](https://en.wikipedia.org/wiki/C_(lang)) x", at: 0, { _ in }, {
                ($0.storage.attribute(.link, at: 1, effectiveRange: nil) as? URL)?.absoluteString.hasSuffix("(lang)") == true
            }, "link URL with parentheses")
            styled("*\u{FE0F}\u{20E3} *hi*", at: 0, { _ in }, { !hidden($0, 0) }, "keycap emoji isn't an italic marker")
            styled("a\u{2028}```\nb\n``", at: 0, { tv in
                tv.setSelectedRange(NSRange(location: tv.textStorage!.length, length: 0))
                tv.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
            }, { !$0.storage.string.contains("\u{2028}") }, "line separators are normalised (no crash)")
            styled("# Title\n", at: 8, { _ in }, { ($0.textView.typingAttributes[.font] as? NSFont)?.pointSize == 15 }, "empty line after heading types body text")
            styled("`![](attachments/a.png)` and\n```\n![](attachments/b.png)\n```", at: 0, { _ in }, {
                $0.storage.attribute(.attachment, in: NSRange(location: 0, length: $0.storage.length)) == nil
            }, "image syntax in code stays text")
            styled("![](attachments/a(1).png)", at: 0, { _ in }, { $0.storage.length == 1 }, "attachment path with parentheses")
        }

        // Floating makes the glass clearer: fixed points, bounds, and no jumps.
        do {
            let e = { (d: Double) in GlassAppearance.effectiveDensity(d, floating: true) }
            let close = { (a: Double, b: Double) in abs(a - b) < 1e-9 }
            var ok = close(e(0), 0) && close(e(0.1), 0.05) && close(e(0.35), 0.23) && close(e(1), 0.88)
            ok = ok && close(GlassAppearance.effectiveDensity(0.6, floating: false), 0.6)   // not floating: unchanged
            ok = ok && close(e(-1), 0) && close(e(2), 0.88)                                // out-of-range input clamps
            var previous = -1.0
            for i in 0...1000 {                                                            // monotonic, always clearer,
                let d = Double(i) / 1000                                                   // never more than halved
                let v = e(d)
                ok = ok && v >= previous - 1e-12 && v <= d && v >= d * 0.5 - 1e-12 && d - v <= GlassAppearance.floatingShift + 1e-12
                previous = v
            }
            if ok { passed += 1 } else { failures += 1; print("FAIL floating density curve") }
        }

        // The global shortcut is opt-in.
        if UserDefaults.standard.object(forKey: "globalHotKey") != nil || !Preferences.globalHotKey { passed += 1 }
        else { failures += 1; print("FAIL hotkey should default to off") }

        // Cursor beside a tall inline image is text height, on the text's baseline.
        do {
            let img = NSImage(size: NSSize(width: 400, height: 300))
            img.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 400, height: 300).fill(); img.unlockFocus()
            let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            let rel = Store.shared.importData(png, ext: "png", base: "tall")!
            let stack = MarkdownEditorStack()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.documentView = stack.textView
            stack.textView.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
            window.contentView = scroll
            stack.load(markdown: "a\n![](\(rel))bc")
            stack.layoutManager.ensureLayout(for: stack.container)
            let end = stack.storage.length
            let caret = stack.textView.caretRect(at: end)
            let lineHeight = stack.layoutManager.lineFragmentRect(forGlyphAt: end - 1, effectiveRange: nil).height
            let plain = stack.textView.caretRect(at: 1)
            if let caret, let plain, lineHeight > 200, caret.height < 30, abs(caret.height - plain.height) < 1,
               caret.maxY > lineHeight - 10 {   // sits at the bottom of the tall line, by the text
                passed += 1
            } else {
                failures += 1
                print("FAIL caret height: caret=\(String(describing: caret)) plain=\(String(describing: plain)) line=\(lineHeight)")
            }
        }

        // Big page: styling + incremental edit should stay fast.
        do {
            let line = "- item with **bold** and `code` and a [link](https://example.com)\n"
            let big = String(repeating: line, count: 20_000)
            let stack = MarkdownEditorStack()
            // Same view hierarchy as the real window: only the visible part gets laid out.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.documentView = stack.textView
            stack.textView.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
            window.contentView = scroll
            let t0 = Date()
            stack.load(markdown: big)
            let loadMs = Date().timeIntervalSince(t0) * 1000
            stack.textView.setSelectedRange(NSRange(location: 10, length: 0))
            let t1 = Date()
            for _ in 0..<50 { stack.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0)) }
            let typeMs = Date().timeIntervalSince(t1) * 1000 / 50
            // Again once the rest of the page is styled (what you type into a moment after launch).
            stack.finishStyling()
            let t2 = Date()
            for _ in 0..<50 { stack.textView.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0)) }
            let styledMs = Date().timeIntervalSince(t2) * 1000 / 50
            print(String(format: "perf: load 20k lines %.0f ms, per keystroke %.2f ms (%.2f ms once fully styled)", loadMs, typeMs, styledMs))
            if typeMs < 16, styledMs < 16 { passed += 1 } else { failures += 1; print("FAIL keystroke too slow") }
        }

        // Big page: opening or closing a fence restyles only what changed role
        // near the edit; the rest of the page is styled afterwards in chunks.
        // (Restyling everything below took ~650 ms to open, ~900 ms for Return.)
        do {
            let para = "Some prose with a https://example.com link, **bold**, _italic_ and `code` here.\n"
            let stack = MarkdownEditorStack()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                                  styleMask: [.titled], backing: .buffered, defer: true)
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.documentView = stack.textView
            stack.textView.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
            window.contentView = scroll
            stack.load(markdown: "intro\n\n" + String(repeating: para, count: 20_000))
            stack.finishStyling()
            let tv = stack.textView
            func ms(_ f: () -> Void) -> Double { let t = Date(); f(); return Date().timeIntervalSince(t) * 1000 }
            func key(_ s: String) { tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            // Best of three, so a busy machine doesn't fail it; the old code took 650-900 ms.
            var open = Double.infinity, info = Double.infinity, close = Double.infinity, reopen = Double.infinity
            for _ in 0..<3 {
                tv.setSelectedRange(NSRange(location: 6, length: 0))
                open = min(open, (0..<3).map { _ in ms { key("`") } }.max()!)   // the third one opens a block to the end
                info = min(info, ms { key("j") })
                close = min(close, ms { tv.insertNewline(nil) })                // auto-closes: everything below is prose again
                stack.finishStyling()
                // "intro\n```j\n\n```\nSome…": backspace at the end of the closing fence
                // makes it "``", so the block is open to the end of the page again.
                tv.setSelectedRange(NSRange(location: 15, length: 0))
                reopen = min(reopen, ms { tv.deleteBackward(nil) })
                stack.finishStyling()
                tv.insertText("", replacementRange: NSRange(location: 6, length: 8))   // back to "intro\n\nSome…"
                stack.finishStyling()
            }
            let unchanged = stack.markdown() == "intro\n\n" + String(repeating: para, count: 20_000)
            print(String(format: "perf: fence open %.1f ms, info string %.1f ms, Return auto-close %.1f ms, backspace %.1f ms", open, info, close, reopen))
            #if DEBUG
            let limit: Double = 32   // unoptimised build; release stays under 16
            #else
            let limit: Double = 16
            #endif
            for (name, v) in [("open", open), ("info string", info), ("Return", close), ("backspace", reopen)] {
                if v < limit, unchanged { passed += 1 } else { failures += 1; print("FAIL fence \(name) keystroke too slow: \(v) ms (text intact: \(unchanged))") }
            }
        }

        // Deferred styling stays correct when you keep editing before it finishes:
        // once it's done, every character looks exactly as after a fresh load.
        do {
            func fingerprint(_ s: NSTextStorage) -> [String] {
                var out: [String] = []
                var tokens: [ObjectIdentifier: Int] = [:]
                s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { a, r, _ in
                    var t = "-"
                    if let c = a[.jotCodeRegion] as? CodeRegion {
                        let id = ObjectIdentifier(c)
                        if tokens[id] == nil { tokens[id] = tokens.count }
                        t = "C\(tokens[id]!)\(c.closed ? "c" : "o")"
                    }
                    let f = (a[.font] as? NSFont).map { "\($0.pointSize)\($0.isFixedPitch ? "m" : "")\(NSFontManager.shared.traits(of: $0).rawValue)" } ?? "-"
                    let flags = [a[.jotFence] != nil, a[.jotHidden] != nil, a[.jotPrefix] != nil, a[.jotMarker] != nil, a[.link] != nil, a[.jotQuote] != nil]
                        .map { $0 ? "1" : "0" }.joined()
                    let entry = "\(t)|\(flags)|\(f)"
                    if out.last?.hasPrefix(entry + "@") == true { return }   // runs split by keys we don't compare
                    out.append(entry + "@\(r.location)")
                }
                return out
            }
            let section = "## Notes\n- item with **bold**\n- [ ] task\n> quoted\nplain text with `code` and a [link](https://x.org)\n![](attachments/a.png) and [r.pdf](attachments/r.pdf)\n```swift\nlet x = 1\n```\n\n"
            let page = String(repeating: section, count: 400)   // ~40k characters: more than is styled at once
            let stack = MarkdownEditorStack()
            stack.load(markdown: page)
            let tv = stack.textView
            func key(_ s: String) { tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            let deferredAfterLoad = !stack.styler.pending.isEmpty
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            key("```\n")                                              // opens a block: every pair below flips
            stack.styler.stylePending(budget: 1, maxChunks: 3)
            tv.setSelectedRange(NSRange(location: 20_000, length: 0))
            key("x"); tv.insertNewline(nil); key("```")
            stack.styler.stylePending(budget: 1, maxChunks: 2)
            tv.setSelectedRange(NSRange(location: 4, length: 0))
            tv.deleteBackward(nil)                                     // the opener is gone again
            tv.setSelectedRange(NSRange(location: 30_000, length: 0))
            tv.insertNewline(nil)
            stack.setBaseFontSize(16)                                  // restyles the whole page, deferred
            let duringFontChange = stack.markdown()                    // saving mid-pass keeps every attachment
            stack.finishStyling()
            // The same characters and attachments, styled from scratch. (Not a load of
            // the Markdown: an image that ends up inside a code block while you edit
            // stays an image, where a load keeps it as text. That's unrelated to this.)
            let fresh = MarkdownEditorStack()
            fresh.setBaseFontSize(16)
            fresh.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSAttributedString(attributedString: stack.storage))
            fresh.finishStyling()
            let atoms = duringFontChange.components(separatedBy: "](attachments/").count - 1
            if deferredAfterLoad, stack.styler.pending.isEmpty, fingerprint(stack.storage) == fingerprint(fresh.storage),
               duringFontChange == stack.markdown(), atoms == 800 { passed += 1 }
            else {
                failures += 1
                let a = fingerprint(stack.storage), b = fingerprint(fresh.storage)
                let i = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
                print("FAIL deferred styling differs from a fresh load (deferred: \(deferredAfterLoad), attachments: \(atoms), same text: \(duringFontChange == stack.markdown()), first diff: \(i < a.count ? a[i] : "-") vs \(i < b.count ? b[i] : "-"))")
            }
        }

        print("selftest: \(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
