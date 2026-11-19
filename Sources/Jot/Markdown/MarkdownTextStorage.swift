import AppKit

/// Restyles edited paragraphs from inside processEditing, via the delegate hook,
/// so styling lands in the same layout pass as the keystroke.
///
/// Deliberately *not* an NSTextStorage subclass: a Swift subclass has to return
/// `string` as a Swift String, which copies the whole document every time
/// TextKit asks for it (it asks per glyph) and made big pages crawl.
final class MarkdownStylingDelegate: NSObject, NSTextStorageDelegate {
    let styler: MarkdownStyler

    init(styler: MarkdownStyler) { self.styler = styler }

    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        _ = styler.restyle(textStorage, edited: editedRange, delta: delta)
    }
}

extension NSTextStorage {
    func restyleAll(with styler: MarkdownStyler) {
        beginEditing()
        styler.restyleAll(self)
        endEditing()
    }
}
