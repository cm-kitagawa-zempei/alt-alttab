import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "launch at login" toggle.
///
/// Registration binds to the RUNNING bundle's path — running from
/// `/Applications` (the `make install` setup) is the supported configuration;
/// launching a `build/` copy would register that path instead, and the login
/// item would point at a location that may not exist on next boot.
///
/// This type is deliberately dumb: it does not log. Callers log failures via
/// `logToStderr` (see `KeyboardHook.swift`).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
