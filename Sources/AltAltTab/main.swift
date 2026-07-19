import AppKit
import Carbon

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    var hook: KeyboardHook!
    var switcher: SwitcherController!
    let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Permissions.accessibilityGranted {
            Permissions.promptAccessibility()
        }

        switcher = SwitcherController()
        hook = KeyboardHook(delegate: switcher)
        hook.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⇥"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let accessibilityStatus = Permissions.accessibilityGranted ? "✓" : "✗"
        let accessibilityItem = NSMenuItem(title: "アクセシビリティ: \(accessibilityStatus)", action: nil, keyEquivalent: "")
        accessibilityItem.isEnabled = false
        menu.addItem(accessibilityItem)

        let screenRecordingStatus = Permissions.screenRecordingGranted ? "✓" : "✗"
        let screenRecordingItem = NSMenuItem(title: "画面収録: \(screenRecordingStatus)", action: nil, keyEquivalent: "")
        screenRecordingItem.isEnabled = false
        menu.addItem(screenRecordingItem)

        let tapStatus = hook.isTapActive ? "有効" : "無効"
        let tapItem = NSMenuItem(title: "イベントタップ: \(tapStatus)", action: nil, keyEquivalent: "")
        tapItem.isEnabled = false
        menu.addItem(tapItem)

        if IsSecureEventInputEnabled() {
            let secureInputItem = NSMenuItem(
                title: "⚠ セキュア入力中 — Cmd+Tab はシステム標準に戻ります",
                action: nil,
                keyEquivalent: ""
            )
            secureInputItem.isEnabled = false
            menu.addItem(secureInputItem)
        }

        menu.addItem(.separator())

        let openAccessibilityItem = NSMenuItem(
            title: "アクセシビリティ設定を開く…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        openAccessibilityItem.target = self
        menu.addItem(openAccessibilityItem)

        let openScreenRecordingItem = NSMenuItem(
            title: "画面収録設定を開く…",
            action: #selector(openScreenRecordingSettings),
            keyEquivalent: ""
        )
        openScreenRecordingItem.target = self
        menu.addItem(openScreenRecordingItem)

        if !Permissions.screenRecordingGranted {
            let requestScreenRecordingItem = NSMenuItem(
                title: "画面収録を許可…",
                action: #selector(requestScreenRecording),
                keyEquivalent: ""
            )
            requestScreenRecordingItem.target = self
            menu.addItem(requestScreenRecordingItem)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "設定…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "Alt-AltTab を終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func openScreenRecordingSettings() {
        Permissions.openScreenRecordingSettings()
    }

    @objc private func requestScreenRecording() {
        Permissions.requestScreenRecording()
    }
}
