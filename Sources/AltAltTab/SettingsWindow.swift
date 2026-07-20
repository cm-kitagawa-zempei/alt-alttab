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
        window.title = "Alt-AltTab 設定"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()

        return window
    }
}

/// The settings form. Three toggles bound straight to `AppSettings.shared`;
/// each write persists to UserDefaults, and the switcher reads the values fresh
/// at every session begin. A fourth toggle ("ログイン時に自動起動") is NOT
/// UserDefaults-backed — its source of truth is `SMAppService` status via
/// `LoginItem`, which the user can also change from System Settings, so the
/// local `@State` is refreshed from it on every appearance.
private struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    /// Guards against `onChange` re-firing when we programmatically revert
    /// `launchAtLogin` after a failed `LoginItem.setEnabled` call.
    @State private var isReverting = false

    var body: some View {
        Form {
            Toggle("最小化中のウィンドウを表示", isOn: $settings.showMinimizedWindows)
            Toggle("非表示アプリのウィンドウを表示", isOn: $settings.showHiddenAppWindows)
            Toggle("最小化中のウィンドウを暗く表示", isOn: $settings.dimMinimizedWindows)

            Section {
                Toggle("ログイン時に自動起動", isOn: $launchAtLogin)
            } footer: {
                Text("/Applications にインストールした状態（make install）での利用を想定しています。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            // The window is created once and reused; the toggle may have
            // drifted (e.g. the user disabled the login item from System
            // Settings) while it was closed, so re-sync on every appearance.
            launchAtLogin = LoginItem.isEnabled
        }
        .onChange(of: launchAtLogin) { _, newValue in
            if isReverting {
                isReverting = false
                return
            }
            guard newValue != LoginItem.isEnabled else { return }
            do {
                try LoginItem.setEnabled(newValue)
            } catch {
                logToStderr("LoginItem.setEnabled(\(newValue)) failed: \(error)")
                isReverting = true
                launchAtLogin = LoginItem.isEnabled
            }
        }
    }
}
