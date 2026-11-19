import AppKit

extension Notification.Name {
    static let jotPreferencesChanged = Notification.Name("jotPreferencesChanged")
}

/// Tiny UserDefaults-backed settings. Posts .jotPreferencesChanged on writes.
enum Preferences {
    private static let defaults = UserDefaults.standard

    /// 0 = clear glass, 1 = frosted / nearly solid.
    static var glassDensity: Double {
        get { defaults.object(forKey: "glassDensity") as? Double ?? 0.35 }
        set { defaults.set(newValue, forKey: "glassDensity"); changed() }
    }

    static var floatOnTop: Bool {
        get { defaults.object(forKey: "floatOnTop") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "floatOnTop"); changed() }
    }

    /// ⌥Space shows/hides Jot from anywhere. Off by default: Jot behaves like
    /// a normal app (Dock, ⌘Tab, Spotlight) unless you opt in.
    static var globalHotKey: Bool {
        get { defaults.object(forKey: "globalHotKey") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "globalHotKey"); changed() }
    }

    /// Set when turning the hotkey on failed (e.g. another app owns ⌥Space).
    /// Runtime only; shown in Settings.
    static var hotKeyProblem: String?

    static var fontSize: CGFloat {
        get { defaults.object(forKey: "fontSize") as? CGFloat ?? 15 }
        set { defaults.set(min(max(newValue, 10), 32), forKey: "fontSize"); changed() }
    }

    private static func changed() {
        NotificationCenter.default.post(name: .jotPreferencesChanged, object: nil)
    }
}
