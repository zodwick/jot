import AppKit

/// ⌘, — one small pane, plain AppKit (no SwiftUI needed).
enum SettingsWindow {
    static func make() -> NSWindow {
        let controller = SettingsViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = "Jot Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

private final class SettingsViewController: NSViewController {
    private let density = NSSlider(value: Preferences.glassDensity, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let floatOnTop = NSButton(checkboxWithTitle: "Float on top of other windows", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let sizeStepper = NSStepper()

    override func loadView() {
        density.target = self
        density.action = #selector(densityChanged)
        density.isContinuous = true
        density.widthAnchor.constraint(equalToConstant: 200).isActive = true

        floatOnTop.target = self
        floatOnTop.action = #selector(floatChanged)

        sizeStepper.minValue = 10
        sizeStepper.maxValue = 32
        sizeStepper.increment = 1
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeChanged)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let densityRow = NSStackView(views: [small("Clear"), density, small("Frosted")])
        densityRow.spacing = 8
        let sizeRow = NSStackView(views: [sizeLabel, sizeStepper])
        sizeRow.spacing = 6

        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(reveal))
        reveal.bezelStyle = .push

        let hotkey = NSTextField(labelWithString: "⌥ Space")
        hotkey.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [label("Glass:"), densityRow],
            [NSGridCell.emptyContentView, floatOnTop],
            [label("Text size:"), sizeRow],
            [label("Show / hide:"), hotkey],
            [label("Page:"), reveal],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12
        grid.columnSpacing = 10

        let footer = NSTextField(wrappingLabelWithString:
            "Everything saves automatically as plain Markdown. A daily backup of the last 7 days is kept next to it.")
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.preferredMaxLayoutWidth = 380

        let stack = NSStackView(views: [grid, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        view = stack
        refresh()
    }

    private func refresh() {
        density.doubleValue = Preferences.glassDensity
        floatOnTop.state = Preferences.floatOnTop ? .on : .off
        sizeStepper.doubleValue = Double(Preferences.fontSize)
        sizeLabel.stringValue = "\(Int(Preferences.fontSize)) pt"
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    @objc private func densityChanged() { Preferences.glassDensity = density.doubleValue }
    @objc private func floatChanged() { Preferences.floatOnTop = floatOnTop.state == .on }
    @objc private func sizeChanged() {
        Preferences.fontSize = CGFloat(sizeStepper.doubleValue)
        refresh()
    }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([Store.shared.pageURL]) }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
    private func small(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        return f
    }
}
