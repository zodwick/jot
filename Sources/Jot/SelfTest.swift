import AppKit

/// `JOT_SELFTEST=1 Jot` runs scripted editing cases through the real editor
/// (same command methods a key press triggers) and exits non-zero on failure.
/// "|" in a case marks the caret (or "[" … "]" style selection via `select`).
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
        check("checkbox toggle via text", "- [ ] a|", expect: "- [ ] a\n- [ ] b|") { tv in
            tv.insertNewline(nil); tv.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        // Atoms round-trip through load → save and copy.
        do {
            let stack = MarkdownEditorStack()
            let md = "before\n![](attachments/a.png)\nmid [r.pdf](attachments/r.pdf) after\n"
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
            if md2.contains("\n![](attachments/image-"), md2.hasSuffix(".png)\n") { passed += 1 }
            else { failures += 1; print("FAIL paste image: \(md2.debugDescription)") }
            pb.releaseGlobally()
        }

        // Images are blocks: own line on load, caret never rests beside one,
        // Backspace below selects it first, then deletes it.
        do {
            let stack = MarkdownEditorStack()
            stack.load(markdown: "a\n![](attachments/x.png)b")
            let tv = stack.textView
            var ok = stack.markdown() == "a\n![](attachments/x.png)\nb"   // split onto its own line
            // storage: "a"0 "\n"1 IMG2 "\n"3 "b"4
            tv.setSelectedRange(NSRange(location: 1, length: 0))
            tv.moveRight(nil)
            ok = ok && tv.selectedRange().location == 4                    // skips the image line
            tv.moveLeft(nil)
            ok = ok && tv.selectedRange().location == 1                    // and back over it
            tv.setSelectedRange(NSRange(location: 4, length: 0))
            tv.deleteBackward(nil)
            ok = ok && tv.selectedRange() == NSRange(location: 2, length: 1) // first: selects the image
            tv.deleteBackward(nil)
            ok = ok && stack.markdown() == "a\n\nb"                         // second: deletes it
            if ok { passed += 1 } else { failures += 1; print("FAIL image block: \(stack.markdown().debugDescription) sel=\(tv.selectedRange())") }

            let end = MarkdownEditorStack()
            end.load(markdown: "x![](attachments/x.png)")
            if end.markdown() == "x\n![](attachments/x.png)\n" { passed += 1 }
            else { failures += 1; print("FAIL image at end: \(end.markdown().debugDescription)") }
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
            print(String(format: "perf: load 20k lines %.0f ms, per keystroke %.2f ms", loadMs, typeMs))
            if typeMs < 16 { passed += 1 } else { failures += 1; print("FAIL keystroke too slow") }
        }

        print("selftest: \(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
