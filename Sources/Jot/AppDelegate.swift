import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowController: MainWindowController!
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["JOT_SELFTEST"] != nil { SelfTest.run() }

        // Another Jot already has this page open (e.g. a second copy of the app):
        // bring that one forward instead of opening the same file twice.
        guard Store.shared.acquireLock() else {
            let me = NSRunningApplication.current
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.jot.app")
                .first { $0 != me }?
                .activate()
            exit(0)
        }

        NSApp.mainMenu = buildMainMenu()
        windowController = MainWindowController()
        windowController.showWindow(nil)
        NSApp.activate()

        updateHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(updateHotKey),
                                               name: .jotPreferencesChanged, object: nil)
    }

    /// Registers or releases the optional ⌥Space hotkey to match Preferences.
    @objc private func updateHotKey() {
        let wanted = Preferences.globalHotKey
        guard wanted != (hotKey != nil) else { return }
        guard wanted else {
            hotKey = nil   // deinit unregisters it
            return
        }
        hotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.toggleFromHotKey() }
        if hotKey == nil {
            // Taken by another app (or the system): turn the setting back off and say why.
            Preferences.hotKeyProblem = "⌥Space is already used by another app."
            Preferences.globalHotKey = false
        } else {
            Preferences.hotKeyProblem = nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.showWindow(nil)
        return true
    }

    func applicationWillResignActive(_ notification: Notification) { windowController.flush() }
    func applicationWillTerminate(_ notification: Notification) { windowController.flush() }

    /// Closing the window just hides it; the page lives on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func toggleFromHotKey() {
        if NSApp.isActive, windowController.window?.isKeyWindow == true {
            NSApp.hide(nil)
        } else {
            windowController.showWindow(nil)
            NSApp.activate()
        }
    }

    // MARK: Actions

    @objc func toggleFloatOnTop(_ sender: Any?) { Preferences.floatOnTop.toggle() }
    @objc func increaseFontSize(_ sender: Any?) { Preferences.fontSize += 1 }
    @objc func decreaseFontSize(_ sender: Any?) { Preferences.fontSize -= 1 }
    @objc func resetFontSize(_ sender: Any?) { Preferences.fontSize = 15 }
    @objc func revealPageInFinder(_ sender: Any?) {
        windowController.flush()
        NSWorkspace.shared.activateFileViewerSelecting([Store.shared.pageURL])
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindow.make() }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleFloatOnTop(_:)) { item.state = Preferences.floatOnTop ? .on : .off }
        return true
    }

    // MARK: Menu

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Jot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Jot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Jot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addSubmenu(appMenu, title: "Jot")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Show Page in Finder", action: #selector(revealPageInFinder(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addSubmenu(file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)))
        find.addItem(item("Find and Replace…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: Int(NSFindPanelAction.replace.rawValue), mods: [.command, .option]))
        find.addItem(item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: Int(NSFindPanelAction.next.rawValue)))
        find.addItem(item("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "G", tag: Int(NSFindPanelAction.previous.rawValue)))
        find.addItem(item("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e", tag: Int(NSFindPanelAction.setFindString.rawValue)))
        edit.addSubmenu(find, title: "Find")
        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        spelling.addItem(withTitle: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        spelling.addItem(withTitle: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")
        edit.addSubmenu(spelling, title: "Spelling and Grammar")
        let subs = NSMenu(title: "Substitutions")
        subs.addItem(withTitle: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        subs.addItem(withTitle: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        subs.addItem(withTitle: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
        edit.addSubmenu(subs, title: "Substitutions")
        main.addSubmenu(edit, title: "Edit")

        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Bold", action: #selector(EditorTextView.toggleBold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(EditorTextView.toggleItalic(_:)), keyEquivalent: "i")
        format.addItem(withTitle: "Inline Code", action: #selector(EditorTextView.toggleInlineCode(_:)), keyEquivalent: "e")
        format.addItem(withTitle: "Strikethrough", action: #selector(EditorTextView.toggleStrikethrough(_:)), keyEquivalent: "X")
        format.addItem(.separator())
        format.addItem(withTitle: "Bulleted List", action: #selector(EditorTextView.toggleBulletList(_:)), keyEquivalent: "8")
        format.addItem(withTitle: "Numbered List", action: #selector(EditorTextView.toggleNumberedList(_:)), keyEquivalent: "7")
        format.addItem(withTitle: "Checklist", action: #selector(EditorTextView.toggleChecklist(_:)), keyEquivalent: "L")
        format.addItem(.separator())
        format.addItem(item("Indent", #selector(EditorTextView.indentLines(_:)), "]"))
        format.addItem(item("Outdent", #selector(EditorTextView.outdentLines(_:)), "["))
        main.addSubmenu(format, title: "Format")

        let view = NSMenu(title: "View")
        view.addItem(item("Float on Top", #selector(toggleFloatOnTop(_:)), "p", mods: [.command, .shift]))
        view.addItem(.separator())
        view.addItem(withTitle: "Bigger Text", action: #selector(increaseFontSize(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller Text", action: #selector(decreaseFontSize(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(resetFontSize(_:)), keyEquivalent: "0")
        main.addSubmenu(view, title: "View")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addSubmenu(window, title: "Window")
        NSApp.windowsMenu = window

        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String, tag: Int = 0, mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.tag = tag
        item.keyEquivalentModifierMask = mods
        return item
    }
}

private extension NSMenu {
    func addSubmenu(_ submenu: NSMenu, title: String) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        holder.submenu = submenu
        addItem(holder)
    }
}
