import Foundation
import Observation

/// UserDefaults-backed user settings. `@Observable` so SwiftUI (the settings
/// window's toggles, the switcher cells' dimming) reacts to changes live;
/// `SwitcherController` reads it fresh at each `beginSession`, so there is no
/// session-level caching to invalidate.
///
/// The module is `MainActor`-isolated by default, so this singleton lives on
/// the main actor without annotation.
///
/// Note: 「ログイン時に自動起動」is NOT one of these settings — it is managed
/// via `SMAppService` in `LoginItem.swift`, whose own status is the source of
/// truth (not persisted here), since the user can also toggle it from System
/// Settings.
@Observable final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let showMinimizedWindows = "showMinimizedWindows"
        static let showHiddenAppWindows = "showHiddenAppWindows"
        static let dimMinimizedWindows = "dimMinimizedWindows"
    }

    /// Include minimized windows in the switcher. Default true (current behavior).
    var showMinimizedWindows: Bool {
        didSet { UserDefaults.standard.set(showMinimizedWindows, forKey: Keys.showMinimizedWindows) }
    }

    /// Include windows of hidden (Cmd+H) apps in the switcher. Default true.
    var showHiddenAppWindows: Bool {
        didSet { UserDefaults.standard.set(showHiddenAppWindows, forKey: Keys.showHiddenAppWindows) }
    }

    /// Dim the thumbnail of minimized windows (the badge always shows; dimming
    /// is the cosmetic part). Default true.
    var dimMinimizedWindows: Bool {
        didSet { UserDefaults.standard.set(dimMinimizedWindows, forKey: Keys.dimMinimizedWindows) }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.showMinimizedWindows: true,
            Keys.showHiddenAppWindows: true,
            Keys.dimMinimizedWindows: true,
        ])
        showMinimizedWindows = defaults.bool(forKey: Keys.showMinimizedWindows)
        showHiddenAppWindows = defaults.bool(forKey: Keys.showHiddenAppWindows)
        dimMinimizedWindows = defaults.bool(forKey: Keys.dimMinimizedWindows)
    }
}
