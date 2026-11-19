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

    static var fontSize: CGFloat {
        get { defaults.object(forKey: "fontSize") as? CGFloat ?? 15 }
        set { defaults.set(min(max(newValue, 10), 32), forKey: "fontSize"); changed() }
    }

    private static func changed() {
        NotificationCenter.default.post(name: .jotPreferencesChanged, object: nil)
    }
}
