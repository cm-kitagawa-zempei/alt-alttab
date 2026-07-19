import AppKit
import SwiftUI

/// Owns the (single, lazily-created, reused) settings window. Unlike the
/// switcher overlay, this is a NORMAL activating window: it is only ever opened
/// from the status menu — never during a switching session — so taking key here
/// cannot interfere with the non-activating switcher panel flow.
///
/// The module is `MainActor`-isolated by default, so this class is on the
/// main actor without annotation.
final class SettingsWindowController {
    private var _window: NSWindow?

    func show() {
        let window = _window ?? makeWindow()
        _window = window
        // Accessory-policy app: activate explicitly so the window is usable.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hostingView = NSHostingView(rootView: SettingsView())

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AltAltTab 設定"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()

        return window
    }
}

/// The settings form. Three toggles bound straight to `AppSettings.shared`;
/// each write persists to UserDefaults, and the switcher reads the values fresh
/// at every session begin.
private struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Toggle("最小化中のウィンドウを表示", isOn: $settings.showMinimizedWindows)
            Toggle("非表示アプリのウィンドウを表示", isOn: $settings.showHiddenAppWindows)
            Toggle("最小化中のウィンドウを暗く表示", isOn: $settings.dimMinimizedWindows)
        }
        .padding(20)
        .frame(width: 340)
    }
}
