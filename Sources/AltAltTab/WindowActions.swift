import AppKit
import ApplicationServices

/// Mid-session actions the switcher can perform on the currently selected
/// window while Cmd is still held: close the window, or hide/quit its owning
/// application. Kept separate from `WindowFocuser` because these mutate the
/// world rather than just raising a window.
///
/// The module is `MainActor`-isolated by default, so these run on the main
/// actor. `hide()`/`terminate()` are asynchronous *requests* — their Bool
/// result means "the request was sent", not "the app is gone"; we log it and
/// never wait on it.
enum WindowActions {

    /// Presses the window's AX close button (the red traffic-light). Works even
    /// on a minimized window. Some windows have no close button — we log and do
    /// nothing in that case.
    static func close(_ window: WindowInfo) {
        guard let button = axElement(window.axWindow, kAXCloseButtonAttribute as String) else {
            logToStderr("WindowActions: no close button for '\(window.displayTitle)' — skipping")
            return
        }
        let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if err != .success {
            logToStderr("WindowActions: close press failed (\(err.rawValue)) for '\(window.displayTitle)'")
        } else {
            logToStderr("WindowActions: closed window '\(window.displayTitle)'")
        }
    }

    /// Hides the owning application (equivalent to Cmd+H).
    static func hide(_ window: WindowInfo) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else {
            logToStderr("WindowActions: hide — pid=\(window.pid) no longer running")
            return
        }
        let ok = app.hide()
        logToStderr("WindowActions: hide '\(window.appName)' -> \(ok)")
    }

    /// Requests the owning application terminate (equivalent to Cmd+Q). Not
    /// `forceTerminate` — this is a polite request, so an app may prompt to save
    /// or (like Finder) simply relaunch; the Bool only reports that the request
    /// was sent.
    static func quit(_ window: WindowInfo) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else {
            logToStderr("WindowActions: quit — pid=\(window.pid) no longer running")
            return
        }
        let ok = app.terminate()
        logToStderr("WindowActions: quit '\(window.appName)' -> \(ok)")
    }
}
