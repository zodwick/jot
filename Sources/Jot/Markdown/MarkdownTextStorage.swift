import AppKit

/// Restyles edited paragraphs from inside processEditing, via the delegate hook,
/// so styling lands in the same layout pass as the keystroke.
///
/// It has to be *did*ProcessEditing: attribute changes made in willProcessEditing
/// widen the storage's editedRange, and NSTextView then moves the caret to the
/// end of that range, so typing mid-line jumped the cursor to the line's end.
/// Apple's docs reserve didProcessEditing for exactly this (attributes only).
///
/// Deliberately *not* an NSTextStorage subclass: a Swift subclass has to return
/// `string` as a Swift String, which copies the whole document every time
/// TextKit asks for it (it asks per glyph) and made big pages crawl.
final class MarkdownStylingDelegate: NSObject, NSTextStorageDelegate {
    let styler: MarkdownStyler

    init(styler: MarkdownStyler) { self.styler = styler }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let restyled = styler.restyle(textStorage, edited: editedRange, delta: delta)
        // AppKit's font fallback (emoji, CJK, symbols) already ran on the old
        // attributes; run it again over what we just restyled.
        textStorage.fixAttributes(in: restyled)
    }
}

extension NSTextStorage {
    func restyleAll(with styler: MarkdownStyler) {
        beginEditing()
        styler.restyleAll(self)
        endEditing()
    }
}
