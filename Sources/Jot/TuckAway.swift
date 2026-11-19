import AppKit

/// Double-click the top strip of the pad (or ⇧⌘M) and Jot tucks into the menu
/// bar: the window goes away and focus returns to the app you were in. The menu
/// bar icon only exists while tucked; clicking it brings the pad back.
final class TuckAway: NSObject {
    private var item: NSStatusItem?
    private let restore: () -> Void

    var isTucked: Bool { item != nil }

    init(restore: @escaping () -> Void) {
        self.restore = restore
    }

    func tuck(_ window: NSWindow) {
        // A full-screen window can't leave its Space empty-handed; ordering it out
        // would leave a blank full-screen Space behind.
        guard !window.styleMask.contains(.fullScreen) else { NSSound.beep(); return }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                // A line glyph like the system's own menu extras (Wi‑Fi, Control
                // Centre), sized to match; template so it follows light/dark menu bars.
                let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Show Jot")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
                image?.isTemplate = true
                button.image = image
                button.toolTip = "Show Jot"
                button.target = self
                button.action = #selector(clicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            self.item = item
        }
        window.orderOut(nil)
        NSApp.hide(nil)   // hand focus back to the app underneath
    }

    /// Removes the menu bar icon. Called whenever the pad comes back, however it
    /// comes back (icon, Dock, ⌘Tab, ⌘1, ⌥Space).
    func untuck() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    @objc private func clicked() { restore() }
}

/// The pad's window: a double-click on its top strip (not on the traffic
/// lights) tucks it away instead of the system's zoom / minimize.
final class JotWindow: NSWindow {
    var onTopStripDoubleClick: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, let onTopStripDoubleClick,
           isInTopStrip(event.locationInWindow) {
            onTopStripDoubleClick()
            return
        }
        super.sendEvent(event)
    }

    private func isInTopStrip(_ p: NSPoint) -> Bool {
        // contentLayoutRect excludes the (transparent) titlebar.
        guard p.y >= contentLayoutRect.maxY, p.y <= frame.height else { return false }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(kind),
               button.convert(button.bounds, to: nil).insetBy(dx: -4, dy: -4).contains(p) { return false }
        }
        return true
    }
}
