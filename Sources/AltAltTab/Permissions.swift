import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {

    /// Whether this process is currently trusted for Accessibility API access.
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user with the system Accessibility permission dialog if not already granted.
    static func promptAccessibility() {
        // kAXTrustedCheckOptionPrompt is imported as a mutable global (not
        // concurrency-safe under Swift 6); its value is the stable literal below.
        let options: [CFString: Any] = ["AXTrustedCheckOptionPrompt" as CFString: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Whether this process currently has Screen Recording access.
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests Screen Recording access, triggering the system prompt if not already granted.
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings directly to the Accessibility privacy pane.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens System Settings directly to the Screen Recording privacy pane.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
