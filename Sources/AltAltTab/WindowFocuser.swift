import AppKit
import ApplicationServices

/// Brings a chosen window to the front. macOS has no single call for "focus this
/// window", so this performs the AltTab-tested sequence: un-minimize if needed,
/// AXRaise, mark main, then activate the owning app. A single delayed retry
/// covers apps (Java/Electron/some cross-platform toolkits) that ignore AXRaise
/// until their process is frontmost.
enum WindowFocuser {

    static func focus(_ window: WindowInfo) {
        // 1. Un-minimize first — a minimized window can't be raised.
        if window.isMinimized {
            let err = AXUIElementSetAttributeValue(
                window.axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse
            )
            if err != .success {
                logToStderr("WindowFocuser: un-minimize failed (\(err.rawValue)) for '\(window.displayTitle)'")
            }
        }

        // 2 + 3. Raise the window and mark it main.
        raiseAndSetMain(window)

        // 4. Activate the owning app (modern no-argument API on macOS 14+).
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            // A hidden app's windows are off-screen but not AX-minimized; unhide
            // before activating so the target window actually comes forward.
            if app.isHidden {
                app.unhide()
            }
            let ok = app.activate()
            if !ok {
                logToStderr("WindowFocuser: activate() returned false for pid=\(window.pid) '\(window.appName)'")
            }
        } else {
            logToStderr("WindowFocuser: pid=\(window.pid) no longer running")
        }

        // 5. One retry ~50 ms later: some apps only honour AXRaise once active.
        //    The Task inherits MainActor isolation (module default), so capturing
        //    `window` stays on the main actor — no Sendable crossing.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            raiseAndSetMain(window)
        }
    }

    /// Steps 2–3 of the sequence, factored out so the retry replays exactly them.
    private static func raiseAndSetMain(_ window: WindowInfo) {
        let raiseErr = AXUIElementPerformAction(window.axWindow, kAXRaiseAction as CFString)
        if raiseErr != .success {
            logToStderr("WindowFocuser: AXRaise failed (\(raiseErr.rawValue)) for '\(window.displayTitle)'")
        }

        let mainErr = AXUIElementSetAttributeValue(
            window.axWindow, kAXMainAttribute as CFString, kCFBooleanTrue
        )
        if mainErr != .success {
            logToStderr("WindowFocuser: set AXMain failed (\(mainErr.rawValue)) for '\(window.displayTitle)'")
        }
    }
}
