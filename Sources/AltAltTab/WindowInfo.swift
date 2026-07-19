import AppKit
import ApplicationServices

/// One switchable window, shared between the enumeration and switcher/UI layers.
///
/// The module is `MainActor`-isolated by default (Package.swift
/// `.defaultIsolation(MainActor.self)`), so instances live on the main actor;
/// `AXUIElement` and `CGImage` are CF types that never leave it.
struct WindowInfo: Identifiable {
    let windowID: CGWindowID
    var id: CGWindowID { windowID }
    let pid: pid_t
    let axWindow: AXUIElement
    let appName: String
    let bundleID: String?
    let title: String
    let appIcon: NSImage?
    let isMinimized: Bool
    /// Whether the owning application is hidden (Cmd+H).
    let isAppHidden: Bool
    let frame: CGRect
    var thumbnail: CGImage?   // filled asynchronously in M3; always nil for now

    /// What the switcher shows as the row label: the window title, falling back
    /// to the app name when the window is untitled (common for browsers/finders
    /// mid-launch).
    var displayTitle: String {
        title.isEmpty ? appName : title
    }
}
